#import "Basic";

Programming :: #import "tbx/programming";

main :: () {
    args := get_command_line_arguments();
    defer array_reset(*args);

    if !Programming.programming_run(args) exit(1);
}
