// Links the iOS build of the Swift compiler into a dylib. `swift::mainEntry` is the same entry
// point the swift-frontend executable uses; Kiln will call it in-process with frontend arguments.
namespace swift {
int mainEntry(int argc, const char **argv);
}

extern "C" int kiln_swift_main(int argc, const char **argv) {
    return swift::mainEntry(argc, argv);
}
