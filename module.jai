/*
Parser-backed programming tools.

Command-line API:
  programming -find_def <file>@<line>:<col> [-dir <path>]
  programming -find_usages <file>@<line>:<col> [-dir <path>]
  programming -rename <file>@<line>:<col> <new_name> [-y] [-dir <path>]

This deliberately scans Jai source files under -dir instead of relying on the
Jai compiler workspace. That means files culled from a normal compilation are
still visible to find-usages and rename.
*/

#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "tbx/parser";

#scope_module

DEFAULT_JAI_MODULES_DIRECTORY :: "C:/Users/ccn/projects/jai/modules";

Tool_Mode :: enum {
    NONE;
    FIND_DEF;
    FIND_USAGES;
    RENAME;
}

Location_Request :: struct {
    filename: string;
    line: int;
    column: int;
}

Program_Options :: struct {
    mode: Tool_Mode;
    request: Location_Request;
    new_name: string;
    apply: bool;
    directory: string;
    include_jai_modules: bool;
    jai_modules_directory: string;
}

Programming_File :: struct {
    path: string;
    source: string;
    root: *Node;
}

Programming_Edit :: struct {
    start: int;
    count: int;
}

path_char_equal :: (a: u8, b: u8) -> bool {
    if a >= #char "A" && a <= #char "Z" a += #char "a" - #char "A";
    if b >= #char "A" && b <= #char "Z" b += #char "a" - #char "A";
    if a == b return true;
    if (a == #char "/" || a == #char "\\") && (b == #char "/" || b == #char "\\") return true;
    return false;
}

path_equal :: (a: string, b: string) -> bool {
    if a.count == b.count {
        for i: 0..a.count-1 {
            if !path_char_equal(a[i], b[i]) return false;
        }
        return true;
    }

    longer := a;
    shorter := b;
    if b.count > a.count {
        longer = b;
        shorter = a;
    }

    start := longer.count - shorter.count;
    if start > 0 && !path_char_equal(longer[start - 1], #char "/") return false;

    for i: 0..shorter.count-1 {
        if !path_char_equal(longer[start + i], shorter[i]) return false;
    }

    return true;
}

path_is_under_directory :: (path: string, directory: string) -> bool {
    if path_equal(path, directory) return true;
    if path.count <= directory.count return false;

    for i: 0..directory.count-1 {
        if !path_char_equal(path[i], directory[i]) return false;
    }

    return path_char_equal(path[directory.count], #char "/");
}

resolve_path :: (path: string, cwd: string) -> string {
    if path.count == 0 return path;

    raw := path;
    if raw.count >= 2 && raw[0] == #char "." && (raw[1] == #char "/" || raw[1] == #char "\\") {
        raw = slice(raw, 2, raw.count - 2);
    }

    result: string;
    if raw.count >= 3 && raw[0] == #char "/" && raw[2] == #char "/" &&
       ((raw[1] >= #char "a" && raw[1] <= #char "z") || (raw[1] >= #char "A" && raw[1] <= #char "Z")) {
        result = tprint("%", raw);
        result[0] = raw[1];
        if result[0] >= #char "a" && result[0] <= #char "z" result[0] -= #char "a" - #char "A";
        result[1] = #char ":";
    } else if raw.count >= 2 && raw[1] == #char ":" {
        result = tprint("%", raw);
    } else if raw[0] == #char "/" || raw[0] == #char "\\" {
        result = tprint("%", raw);
    } else {
        result = tprint("%/%", cwd, raw);
    }

    for i: 0..result.count-1 {
        if result[i] == #char "\\" result[i] = #char "/";
    }

    cleaned: String_Builder;
    i := 0;
    while i < result.count {
        if result[i] == #char "/" && i + 2 < result.count && result[i + 1] == #char "." && result[i + 2] == #char "/" {
            append(*cleaned, "/");
            i += 3;
            continue;
        }

        append(*cleaned, result[i]);
        i += 1;
    }

    result = builder_to_string(*cleaned);
    return result;
}

find_last :: (s: string, c: u8) -> int {
    i := s.count - 1;
    while i >= 0 {
        if s[i] == c return i;
        i -= 1;
    }
    return -1;
}

find_first :: (s: string, c: u8) -> int {
    for i: 0..s.count-1 {
        if s[i] == c return i;
    }
    return -1;
}

parse_positive_int :: (text: string) -> (value: int, ok: bool) {
    if text.count == 0 return 0, false;

    result := 0;
    for c: text {
        if c < #char "0" || c > #char "9" return 0, false;
        result = result * 10 + cast(int)(c - #char "0");
    }

    return result, true;
}

parse_location :: (arg: string, cwd: string) -> (ok: bool, filename: string, line: int, column: int) {
    at_index := find_last(arg, #char "@");
    if at_index < 1 return false, "", 0, 0;

    filename_part := slice(arg, 0, at_index);
    rest := slice(arg, at_index + 1, arg.count - at_index - 1);

    colon_index := find_first(rest, #char ":");
    if colon_index < 1 return false, "", 0, 0;

    line_str := slice(rest, 0, colon_index);
    col_str := slice(rest, colon_index + 1, rest.count - colon_index - 1);

    line_val, line_ok := parse_positive_int(line_str);
    if !line_ok return false, "", 0, 0;

    col_val, col_ok := parse_positive_int(col_str);
    if !col_ok return false, "", 0, 0;

    return true, resolve_path(filename_part, cwd), line_val, col_val;
}

is_identifier_start :: (c: u8) -> bool {
    return (c >= #char "a" && c <= #char "z") ||
           (c >= #char "A" && c <= #char "Z") ||
           c == #char "_";
}

is_identifier_continue :: (c: u8) -> bool {
    return is_identifier_start(c) || (c >= #char "0" && c <= #char "9");
}

is_valid_identifier :: (name: string) -> bool {
    if name.count == 0 return false;
    if !is_identifier_start(name[0]) return false;

    i := 1;
    while i < name.count {
        if !is_identifier_continue(name[i]) return false;
        i += 1;
    }

    return true;
}

collect_jai_files :: (dir: string) -> [] string {
    results: [..] string;

    visitor :: (info: *File_Visit_Info, results: *[..] string) {
        if info.is_directory {
            if info.short_name == ".build" || info.short_name == ".git" {
                info.descend_into_directory = false;
            }
            return;
        }

        name := info.short_name;
        if name.count < 4 return;

        ext: string;
        ext.data = name.data + name.count - 4;
        ext.count = 4;
        if ext == ".jai" array_add(results, copy_string(info.full_name));
    };

    visit_files(dir, recursive = true, *results, visitor, visit_directories = true);
    return results;
}

add_unique_path :: (paths: *[..] string, path: string) {
    for existing: paths.* {
        if path_equal(existing, path) return;
    }

    array_add(paths, copy_string(path));
}

load_project :: (options: Program_Options) -> ([..] Programming_File, [..] Resolver_Input_File, bool) {
    files: [..] Programming_File;
    inputs: [..] Resolver_Input_File;
    ok := true;

    cwd := get_working_directory();
    roots: [..] string;
    array_add(*roots, options.directory);
    if options.include_jai_modules array_add(*roots, options.jai_modules_directory);

    paths: [..] string;
    for root: roots {
        scan_directory := resolve_path(root, cwd);
        raw_paths := collect_jai_files(scan_directory);
        for raw_path: raw_paths {
            add_unique_path(*paths, resolve_path(raw_path, cwd));
        }
    }

    for path: paths {
        source, read_ok := read_entire_file(path);
        if !read_ok {
            log_error("Could not read '%'", path);
            ok = false;
            continue;
        }

        parse_result := parse(source);
        if !parse_result.success {
            log_error("Parser failed for '%' at %:%: %", path, parse_result.error.span.line, parse_result.error.span.column, parse_result.error.message);
            ok = false;
            continue;
        }

        file: Programming_File;
        file.path = path;
        file.source = source;
        file.root = parse_result.root;
        array_add(*files, file);

        input: Resolver_Input_File;
        input.path = path;
        input.root = parse_result.root;
        array_add(*inputs, input);
    }

    return files, inputs, ok;
}

find_project_file :: (files: [] Programming_File, path: string) -> *Programming_File {
    for * file: files {
        if path_equal(file.path, path) return file;
    }
    return null;
}

append_source_slice :: (builder: *String_Builder, source: string, start: int, count: int) {
    if count <= 0 return;

    slice_text: string;
    slice_text.data = source.data + start;
    slice_text.count = count;
    append(builder, slice_text);
}

apply_edits :: (source: string, edits: [] Programming_Edit, new_name: string) -> string {
    sorted: [..] Programming_Edit;
    array_add(*sorted, ..edits);

    for i: 1..sorted.count-1 {
        edit := sorted[i];
        j := i - 1;
        while j >= 0 && sorted[j].start > edit.start {
            sorted[j + 1] = sorted[j];
            j -= 1;
        }
        sorted[j + 1] = edit;
    }

    result: String_Builder;
    cursor := 0;

    for edit: sorted {
        append_source_slice(*result, source, cursor, edit.start - cursor);
        append(*result, new_name);
        cursor = edit.start + edit.count;
    }

    append_source_slice(*result, source, cursor, source.count - cursor);
    return builder_to_string(*result);
}

line_at_span :: (source: string, span: Source_Span) -> string {
    lines := split(source, cast(u8) #char "\n");
    index := span.line - 1;
    if index < 0 || index >= lines.count return "";
    return trim_right(lines[index]);
}

add_unique_edit :: (edits: *[..] Programming_Edit, edit: Programming_Edit) {
    for existing: edits.* {
        if existing.start == edit.start && existing.count == edit.count return;
    }
    array_add(edits, edit);
}

collect_edits_for_file :: (resolver: Resolver_Result, symbol: *Resolver_Symbol, file_path: string) -> [..] Programming_Edit {
    edits: [..] Programming_Edit;

    if symbol != null && path_equal(symbol.file_path, file_path) && symbol.declaration_node != null {
        add_unique_edit(*edits, .{ start = symbol.declaration_node.span.start_position_in_input, count = symbol.declaration_node.span.count });
    }

    for reference: resolver.references {
        if reference.symbol != symbol continue;
        if !path_equal(reference.file_path, file_path) continue;
        if reference.node == null continue;
        add_unique_edit(*edits, .{ start = reference.node.span.start_position_in_input, count = reference.node.span.count });
    }

    return edits;
}

reference_count_for_symbol_in_file :: (resolver: Resolver_Result, symbol: *Resolver_Symbol, file_path: string) -> int {
    edits := collect_edits_for_file(resolver, symbol, file_path);
    return edits.count;
}

print_usages :: (files: [] Programming_File, resolver: Resolver_Result, symbol: *Resolver_Symbol) {
    total := 0;
    for file: files total += reference_count_for_symbol_in_file(resolver, symbol, file.path);

    log("Usages of '%'", symbol.name);
    log(" ");
    log("  Declared at: %@%:%", symbol.file_path, symbol.declaration_node.span.line, symbol.declaration_node.span.column);
    log("  Total usages: %", total);
    log(" ");

    for file: files {
        count := reference_count_for_symbol_in_file(resolver, symbol, file.path);
        if count == 0 continue;

        log("  %  (% occurrences):", file.path, count);

        if symbol.file_path == file.path {
            log("    %: %", symbol.declaration_node.span.line, line_at_span(file.source, symbol.declaration_node.span));
        }

        shown: [..] int;
        for reference: resolver.references {
            if reference.symbol != symbol continue;
            if !path_equal(reference.file_path, file.path) continue;

            already := false;
            for line: shown if line == reference.node.span.line { already = true; break; }
            if already continue;
            array_add(*shown, reference.node.span.line);

            log("    %: %", reference.node.span.line, line_at_span(file.source, reference.node.span));
        }

        log(" ");
    }
}

scope_is_or_descends_from :: (scope: *Resolver_Scope, ancestor: *Resolver_Scope) -> bool {
    current := scope;
    while current != null {
        if current == ancestor return true;
        current = current.parent;
    }
    return false;
}

log_rename_warning_header :: (warnings: *int) {
    if warnings.* == 0 {
        log("Rename Warnings");
        log(" ");
    }
    warnings.* += 1;
}

log_symbol_location :: (prefix: string, symbol: *Resolver_Symbol) {
    if symbol == null || symbol.declaration_node == null {
        log("  % <unknown>", prefix);
        return;
    }

    log("  % %@%:%", prefix, symbol.file_path, symbol.declaration_node.span.line, symbol.declaration_node.span.column);
}

check_rename_conflicts :: (resolver: Resolver_Result, symbol: *Resolver_Symbol, new_name: string) -> int {
    if symbol == null || new_name == symbol.name return 0;

    warnings := 0;

    same_scope_symbol := find_symbol_in_scope(symbol.scope, new_name);
    if same_scope_symbol != null && same_scope_symbol != symbol {
        log_rename_warning_header(*warnings);
        log("  New name '%' already exists in the declaration scope.", new_name);
        log_symbol_location("Existing declaration:", same_scope_symbol);
        log(" ");
    }

    if symbol.scope != null {
        visible_symbol := find_symbol(symbol.scope.parent, new_name);
        if visible_symbol != null && visible_symbol != symbol {
            log_rename_warning_header(*warnings);
            log("  New name '%' would shadow an outer declaration.", new_name);
            log_symbol_location("Shadowed declaration:", visible_symbol);
            log(" ");
        }
    }

    for reference: resolver.references {
        if reference.node == null || reference.scope == null continue;

        if reference.symbol == symbol {
            visible_symbol := find_symbol(reference.scope, new_name);
            if visible_symbol != null && visible_symbol != symbol {
                log_rename_warning_header(*warnings);
                log("  Renamed usage at %@%:% would collide with another visible declaration named '%'.",
                    reference.file_path, reference.node.span.line, reference.node.span.column, new_name);
                log_symbol_location("Visible declaration:", visible_symbol);
                log(" ");
            }
            continue;
        }

        if reference.name != new_name continue;
        if !scope_is_or_descends_from(reference.scope, symbol.scope) continue;

        if reference.scope == symbol.scope && symbol.declaration_node != null &&
           reference.node.span.start_position_in_input < symbol.declaration_node.span.start_position_in_input {
            continue;
        }

        log_rename_warning_header(*warnings);
        log("  Existing reference at %@%:% may be captured by the renamed symbol.",
            reference.file_path, reference.node.span.line, reference.node.span.column);
        if reference.symbol != null log_symbol_location("Currently resolves to:", reference.symbol);
        log(" ");
    }

    return warnings;
}

find_symbol_for_request :: (resolver: Resolver_Result, request: Location_Request) -> *Resolver_Symbol {
    return find_symbol_at_position_in_file(resolver, request.filename, request.line, request.column);
}

run_find_def :: (files: [] Programming_File, resolver: Resolver_Result, options: Program_Options) -> bool {
    symbol := find_symbol_for_request(resolver, options.request);
    if symbol == null {
        log_error("No symbol found at %@%:%", options.request.filename, options.request.line, options.request.column);
        return false;
    }

    log("%@%:%", symbol.file_path, symbol.declaration_node.span.line, symbol.declaration_node.span.column);
    return true;
}

run_find_usages :: (files: [] Programming_File, resolver: Resolver_Result, options: Program_Options) -> bool {
    symbol := find_symbol_for_request(resolver, options.request);
    if symbol == null {
        log_error("No symbol found at %@%:%", options.request.filename, options.request.line, options.request.column);
        return false;
    }

    print_usages(files, resolver, symbol);
    return true;
}

run_rename :: (files: [] Programming_File, resolver: Resolver_Result, options: Program_Options) -> bool {
    if !is_valid_identifier(options.new_name) {
        log_error("New name '%' is not a valid simple Jai identifier.", options.new_name);
        return false;
    }

    symbol := find_symbol_for_request(resolver, options.request);
    if symbol == null {
        log_error("No symbol found at %@%:%", options.request.filename, options.request.line, options.request.column);
        return false;
    }

    if options.include_jai_modules {
        modules_directory := resolve_path(options.jai_modules_directory, get_working_directory());
        if path_is_under_directory(symbol.file_path, modules_directory) {
            log("Rename refused");
            log(" ");
            log("  Symbol:      '%'", symbol.name);
            log("  Declared at: %@%:%", symbol.file_path, symbol.declaration_node.span.line, symbol.declaration_node.span.column);
            log(" ");
            log("This symbol is defined inside the ambient Jai modules directory:");
            log("  %", modules_directory);
            log(" ");
            log("Renaming Jai module symbols is blocked because it could affect every project that uses those modules.");
            return false;
        }
    }

    log("Rename Preview");
    log(" ");
    log("  Symbol:      '%'", symbol.name);
    log("  New name:    '%'", options.new_name);
    log("  Declared at: %@%:%", symbol.file_path, symbol.declaration_node.span.line, symbol.declaration_node.span.column);
    log(" ");

    print_usages(files, resolver, symbol);
    warnings := check_rename_conflicts(resolver, symbol, options.new_name);

    if !options.apply {
        if warnings > 0 {
            log("This rename has % warning(s). It will not be applied with -y until the conflicts are resolved.", warnings);
            return true;
        }
        log("This is a preview. Add -y to apply the rename.");
        return true;
    }

    if warnings > 0 {
        log("Rename not applied because % warning(s) were found.", warnings);
        return false;
    }

    total_edits := 0;
    for file: files {
        edits := collect_edits_for_file(resolver, symbol, file.path);
        if edits.count == 0 continue;

        renamed := apply_edits(file.source, edits, options.new_name);
        if !write_entire_file(file.path, renamed) {
            log_error("Could not write '%'", file.path);
            return false;
        }

        total_edits += edits.count;
        log("  Renamed % occurrences in '%'", edits.count, file.path);
    }

    log(" ");
    log("Done. Applied % edits.", total_edits);
    return true;
}

print_usage :: () {
    log("programming - parser-backed Jai programming tools");
    log(" ");
    log("Usage:");
    log("  programming -find_def <file>@<line>:<col> [-dir <path>]");
    log("  programming -find_usages <file>@<line>:<col> [-dir <path>]");
    log("  programming -rename <file>@<line>:<col> <new_name> [-y] [-dir <path>]");
    log(" ");
    log("Options:");
    log("  -jai_modules <path>  Override the ambient Jai modules directory.");
    log("  -no_jai_modules      Only scan the project directory.");
}

#scope_export

programming_parse_args :: (args: [] string, cwd: string) -> (Program_Options, bool) {
    options: Program_Options;
    options.directory = cwd;
    options.include_jai_modules = true;
    options.jai_modules_directory = DEFAULT_JAI_MODULES_DIRECTORY;

    i := 1;
    while i < args.count {
        arg := args[i];

        if arg == "-help" || arg == "--help" || arg == "-h" {
            print_usage();
            return options, false;
        } else if arg == "-dir" {
            i += 1;
            if i >= args.count {
                log_error("-dir requires a path.");
                return options, false;
            }
            options.directory = resolve_path(args[i], cwd);
        } else if arg == "-jai_modules" {
            i += 1;
            if i >= args.count {
                log_error("-jai_modules requires a path.");
                return options, false;
            }
            options.include_jai_modules = true;
            options.jai_modules_directory = resolve_path(args[i], cwd);
        } else if arg == "-no_jai_modules" {
            options.include_jai_modules = false;
        } else if arg == "-find_def" {
            i += 1;
            if i >= args.count {
                log_error("Incomplete arguments. Usage: -find_def <file>@<line>:<col>");
                return options, false;
            }

            loc_ok, filename, line, col := parse_location(args[i], cwd);
            if !loc_ok {
                log_error("Invalid location. Usage: <file>@<line>:<col>");
                return options, false;
            }

            options.mode = .FIND_DEF;
            options.request = .{ filename = filename, line = line, column = col };
        } else if arg == "-find_usages" {
            i += 1;
            if i >= args.count {
                log_error("Incomplete arguments. Usage: -find_usages <file>@<line>:<col>");
                return options, false;
            }

            loc_ok, filename, line, col := parse_location(args[i], cwd);
            if !loc_ok {
                log_error("Invalid location. Usage: <file>@<line>:<col>");
                return options, false;
            }

            options.mode = .FIND_USAGES;
            options.request = .{ filename = filename, line = line, column = col };
        } else if arg == "-rename" {
            i += 1;
            if i >= args.count {
                log_error("Incomplete rename arguments. Usage: -rename <file>@<line>:<col> <new_name> [-y]");
                return options, false;
            }

            loc_ok, filename, line, col := parse_location(args[i], cwd);
            if !loc_ok {
                log_error("Invalid location. Usage: <file>@<line>:<col>");
                return options, false;
            }

            i += 1;
            if i >= args.count {
                log_error("Incomplete rename arguments. Usage: -rename <file>@<line>:<col> <new_name> [-y]");
                return options, false;
            }

            options.mode = .RENAME;
            options.request = .{ filename = filename, line = line, column = col };
            options.new_name = args[i];
        } else if arg == "-y" {
            options.apply = true;
        } else {
            log_error("Unknown argument '%'", arg);
            return options, false;
        }

        i += 1;
    }

    if options.mode == .NONE {
        print_usage();
        return options, false;
    }

    return options, true;
}

programming_run :: (args: [] string) -> bool {
    cwd := get_working_directory();
    options, args_ok := programming_parse_args(args, cwd);
    if !args_ok return false;

    files, inputs, project_ok := load_project(options);
    if !project_ok return false;

    if options.mode == .FIND_DEF {
        resolver := resolve_project_symbols_for_file(inputs, options.request.filename);
        return run_find_def(files, resolver, options);
    }

    resolver := resolve_project_symbols(inputs);

    if options.mode == {
        case .FIND_USAGES; return run_find_usages(files, resolver, options);
        case .RENAME; return run_rename(files, resolver, options);
        case .NONE;
        case .FIND_DEF;
    }

    return false;
}
