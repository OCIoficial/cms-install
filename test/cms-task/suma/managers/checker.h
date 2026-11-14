// Para probar que el checker se compila con -I managers (como testlib.h)
#include <fstream>
#include <iostream>

inline int verdict(double score, const char *msg) {
  std::cout << score << std::endl;
  std::cerr << msg << std::endl;
  return 0;
}
