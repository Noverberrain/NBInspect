# Hand-written syntax fixture, not a demonstration of dependency inference.
from math import sqrt as root

def transform(values):
    return [root(value) for value in values if value >= 0]

result = transform([1, 4, 9])
