import sys
class HiException(Exception):
    def __init__(self, value):
        self.value = value
class LoException(Exception):
    def __init__(self, value):
        self.value = value
hi = lo = 0
def blowup(n):
    if n % 2 == 1:
        raise LoException(n)
    raise HiException(n)
def lo_function(n):
    global lo
    try:
        blowup(n)
    except LoException:
        lo += 1
def hi_function(n):
    global hi
    try:
        lo_function(n)
    except HiException:
        hi += 1
n = int(sys.argv[1])
for i in range(n - 1, -1, -1):
    hi_function(i)
print(f"Exceptions: HI={hi} / LO={lo}")
