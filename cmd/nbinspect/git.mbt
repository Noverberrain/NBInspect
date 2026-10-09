///|
/// The native transport only launches a fixed Git argv, never a shell.
#borrow(a, b)
extern "C" fn git_bytes(
  operation : Int,
  a : Bytes,
  b : Bytes,
  limit : Int,
) -> Bytes = "nb_git"

///|
fn git_read(
  operation : Int,
  a : String,
  b : String,
  limit : Int,
) -> String raise @nb.InputError {
  if a.contains("\u0000") ||
    b.contains("\u0000") ||
    a.length() > 4096 ||
    b.length() > 4096 {
    raise @nb.Invalid("Git argument contains NUL or exceeds 4096 characters")
  }
  let response = git_bytes(operation, @utf8.encode(a), @utf8.encode(b), limit)
  if response.length() == 0 {
    raise @nb.Invalid("Git process transport failed")
  }
  if response[0] != 0 {
    let reason = match response[0].to_int() {
      1 =>
        "Git command failed (invalid commit, missing object, unsupported Git option or not a repository)"
      2 => "Git output exceeds byte limit"
      3 => "Git command timed out after 30 seconds"
      _ => "cannot launch or read Git; verify Git is installed on PATH"
    }
    raise @nb.Invalid(reason)
  }
  @utf8.decode(response[1:].to_owned()) catch {
    _ => raise @nb.Invalid("Git output or notebook is not UTF-8")
  }
}

///|
fn git_commit(ref_name : String) -> String raise @nb.InputError {
  if ref_name == "" {
    raise @nb.Invalid("empty Git commit reference")
  }
  let value = git_read(0, ref_name + "^{commit}", "", 1024).trim().to_owned()
  if (value.length() != 40 && value.length() != 64) ||
    !value
    .iter()
    .all(fn(c) { ('0' <= c && c <= '9') || ('a' <= c && c <= 'f') }) {
    raise @nb.Invalid("Git did not return a full commit object ID")
  }
  value
}

///|
fn review_git(
  base : String,
  head : String,
  policy : @nb.CheckPolicy,
) -> Json raise @nb.InputError {
  let base_commit = git_commit(base)
  let head_commit = git_commit(head)
  let changes = @nb.parse_git_changes(
    git_read(1, base_commit, head_commit, 16777216),
  )
  let files = review_git_files(changes, policy)
  @nb.git_review_report(base, head, base_commit, head_commit, files, policy~)
}

///|
/// Only an absent local branch is unborn; a broken HEAD is still an error.
fn git_index_base() -> String raise @nb.InputError {
  git_commit("HEAD") catch {
    @nb.Invalid(message) => {
      let branch = git_read(4, "", "", 8192).trim().to_owned()
      if !branch.has_prefix("refs/heads/") ||
        git_read(5, branch, "", 16777216) != "" {
        raise @nb.Invalid(message)
      }
      ""
    }
  }
}

///|
fn review_staged(policy : @nb.CheckPolicy) -> Json raise @nb.InputError {
  let base_commit = git_index_base()
  // One manifest freezes the staged blob IDs; subsequent reads use objects only.
  let changes = @nb.parse_git_changes(git_read(3, base_commit, "", 16777216))
  if git_index_base() != base_commit {
    raise @nb.Invalid(
      "HEAD changed while reading the Git index; retry the review",
    )
  }
  let files = review_git_files(changes, policy)
  @nb.git_review_report(
    "HEAD",
    "INDEX",
    base_commit,
    "",
    files,
    policy~,
    staged=true,
  )
}

///|
fn review_git_files(
  changes : Array[@nb.GitChange],
  policy : @nb.CheckPolicy,
) -> Array[Json] {
  let files : Array[Json] = []
  for change in changes {
    if change.kind == "deleted" {
      files.push(@nb.git_review_file(change, { "status": "deleted" }))
      continue
    }
    let report = try {
      if !["100644", "100755"].contains(change.new_mode) ||
        (
          change.kind != "added" &&
          !["100644", "100755"].contains(change.old_mode)
        ) {
        raise @nb.Invalid(
          "Notebook Git entry is not a regular file; links and submodules are not followed",
        )
      }
      let after = @nb.parse(git_read(2, change.after_blob, "", 52428800))
      if change.kind == "added" {
        @nb.check_report(after, policy~)
      } else {
        let before = @nb.parse(git_read(2, change.before_blob, "", 52428800))
        @nb.review_report(before, after, policy~)
      }
    } catch {
      @nb.Invalid(message) => {
        files.push(@nb.git_review_error(change, message))
        continue
      }
    }
    files.push(@nb.git_review_file(change, report))
  }
  files
}
