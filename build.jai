OUTPUT_EXECUTABLE_NAME :: "programming";
BUILD_ROOT :: #filepath;

#run {
    set_build_options_dc(.{do_output = false});

    w := compiler_create_workspace("Programming Tools");
    options := get_build_options(w);
    options.output_executable_name = OUTPUT_EXECUTABLE_NAME;
    options.output_path = tprint("%/", BUILD_ROOT);
    set_build_options(options, w);

    add_build_file(tprint("%/main.jai", BUILD_ROOT), w);
};

#import "Basic";
#import "Compiler";
