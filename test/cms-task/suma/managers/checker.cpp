// Checker con la convención de CMS: checker <entrada> <salida correcta> <salida del participante>.
// Escribe el puntaje en stdout y el mensaje en stderr.
#include "checker.h"

int main(int argc, char **argv) {
  std::ifstream correct(argv[2]), answer(argv[3]);
  long long expected, got;
  correct >> expected;
  if (!(answer >> got) || got != expected) {
    return verdict(0.0, "Suma incorrecta");
  }
  return verdict(1.0, "Correcto");
}
