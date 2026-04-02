#include "lib.h"
#include "absl/strings/str_cat.h"

namespace testlib {
std::string greet(const std::string& name) {
    return absl::StrCat("Hello, ", name, "!");
}
}
