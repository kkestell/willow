import sys
class Toggle:
    __slots__ = ("state",)
    def __init__(self, state):
        self.state = state
    def activate(self):
        self.state = not self.state
        return self
    def value(self):
        return self.state
class NthToggle(Toggle):
    __slots__ = ("count_max", "counter")
    def __init__(self, state, count_max):
        super().__init__(state)
        self.count_max = count_max
        self.counter = 0
    def activate(self):
        self.counter += 1
        if self.counter >= self.count_max:
            self.state = not self.state
            self.counter = 0
        return self
def run(switch, n):
    value = True
    for _ in range(n):
        value = switch.activate().value()
    print("true" if value else "false")
n = int(sys.argv[1])
run(Toggle(True), n)
run(NthToggle(True, 3), n)
