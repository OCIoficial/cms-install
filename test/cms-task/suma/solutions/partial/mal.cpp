// @ocimatic::expected [st1=OK, st2=WA]
#include <iostream>

int main() {
  long long a, b;
  std::cin >> a >> b;
  std::cout << (a < 10 ? a + b : 0) << std::endl;
}
