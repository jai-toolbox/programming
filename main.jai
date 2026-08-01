#import "Basic";

#load "module.jai";

main :: () {
    args := get_command_line_arguments();
    defer array_reset(*args);

    if args.count >= 2 && args[1] == "bench" {
        if !programming_run_bench_cli(args) exit(1);
        return;
    }

    if args.count >= 2 && args[1] == "server" {
        if !programming_run_server_cli(args) exit(1);
        return;
    }

    if !programming_run(args) exit(1);
}
