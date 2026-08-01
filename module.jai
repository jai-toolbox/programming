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
Windows :: #import "Windows";
#load "../parser/module.jai";

#scope_module

DEFAULT_JAI_MODULES_DIRECTORY :: "C:/Users/ccn/projects/jai/modules";
PROGRAMMING_PROFILE_ENABLED :: false;

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
    force_full_project: bool;
    profile: bool;
    allow_jai_modules_rename: bool;
}

Programming_File :: struct {
    path: string;
    source: string;
    root: *Node;
}

Indexed_Declaration :: struct {
    name: string;
    file_path: string;
    node: *Node;
}

Indexed_Project :: struct {
    files: [..] Programming_File;
    declarations: [..] Indexed_Declaration;
}

tool_profile_summary_file_count := 0;
tool_profile_full_parse_file_count := 0;
tool_profile_summary_declaration_count := 0;
tool_profile_collect_seconds: float64 = 0.0;
tool_profile_read_seconds: float64 = 0.0;
tool_profile_target_parse_seconds: float64 = 0.0;
tool_profile_summary_parse_seconds: float64 = 0.0;

profile_timer_start :: inline () -> Apollo_Time {
    #if PROGRAMMING_PROFILE_ENABLED {
        return current_time_monotonic();
    } else {
        result: Apollo_Time;
        return result;
    }
}

profile_seconds_since :: inline (start: Apollo_Time) -> float64 {
    #if PROGRAMMING_PROFILE_ENABLED {
        return to_float64_seconds(current_time_monotonic() - start);
    } else {
        return 0.0;
    }
}

#if PROGRAMMING_PROFILE_ENABLED {
    reset_tool_profile_counts :: () {
        tool_profile_summary_file_count = 0;
        tool_profile_full_parse_file_count = 0;
        tool_profile_summary_declaration_count = 0;
        tool_profile_collect_seconds = 0.0;
        tool_profile_read_seconds = 0.0;
        tool_profile_target_parse_seconds = 0.0;
        tool_profile_summary_parse_seconds = 0.0;
    }
} else {
    reset_tool_profile_counts :: () {
    }
}

Programming_Edit :: struct {
    start: int;
    count: int;
}

Position_Index :: struct {
    symbols_by_position: Table(string, *Resolver_Symbol);
    symbol_names: Table(string, int);
    reference_names: Table(string, int);
    reference_counts: [..] Reference_Count;
}

Reference_Count :: struct {
    symbol: *Resolver_Symbol;
    count: int;
}

Query_State :: struct {
    files: [..] Programming_File;
    inputs: [..] Resolver_Input_File;
    resolver: Resolver_Result;
    index: Position_Index;
    symbol: *Resolver_Symbol;
    request_key: string;
    scanned_files: int;
    promoted_files: int;
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

jai_modules_directory_for_options :: (options: Program_Options) -> string {
    return resolve_path(options.jai_modules_directory, get_working_directory());
}

path_is_in_jai_modules :: (path: string, options: Program_Options) -> bool {
    if !options.include_jai_modules return false;
    modules_directory := jai_modules_directory_for_options(options);
    return path_is_under_directory(path, modules_directory);
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
    last_was_slash := false;
    while i < result.count {
        if result[i] == #char "/" && i + 2 < result.count && result[i + 1] == #char "." && result[i + 2] == #char "/" {
            if !last_was_slash append(*cleaned, "/");
            last_was_slash = true;
            i += 3;
            continue;
        }

        if result[i] == #char "/" {
            if last_was_slash {
                i += 1;
                continue;
            }
            last_was_slash = true;
        } else {
            last_was_slash = false;
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

programming_is_identifier_start :: (c: u8) -> bool {
    return (c >= #char "a" && c <= #char "z") ||
           (c >= #char "A" && c <= #char "Z") ||
           c == #char "_";
}

programming_is_identifier_continue :: (c: u8) -> bool {
    return programming_is_identifier_start(c) || (c >= #char "0" && c <= #char "9");
}

is_valid_identifier :: (name: string) -> bool {
    if name.count == 0 return false;
    if !programming_is_identifier_start(name[0]) return false;

    i := 1;
    while i < name.count {
        if !programming_is_identifier_continue(name[i]) return false;
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

    profile_start: Apollo_Time;
    profile_start = profile_timer_start();
    paths: [..] string;
    for root: roots {
        scan_directory := resolve_path(root, cwd);
        raw_paths := collect_jai_files(scan_directory);
        for raw_path: raw_paths {
            add_unique_path(*paths, resolve_path(raw_path, cwd));
        }
    }
    if PROGRAMMING_PROFILE_ENABLED tool_profile_collect_seconds += profile_seconds_since(profile_start);

    for path: paths {
        profile_start = profile_timer_start();
        source, read_ok := read_entire_file(path);
        if PROGRAMMING_PROFILE_ENABLED tool_profile_read_seconds += profile_seconds_since(profile_start);
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

load_project_for_find_def :: (options: Program_Options) -> ([..] Programming_File, [..] Resolver_Input_File, bool) {
    files: [..] Programming_File;
    inputs: [..] Resolver_Input_File;
    ok := true;

    cwd := get_working_directory();
    target_path := resolve_path(options.request.filename, cwd);

    roots: [..] string;
    array_add(*roots, options.directory);
    if options.include_jai_modules array_add(*roots, options.jai_modules_directory);

    profile_start: Apollo_Time;
    profile_start = profile_timer_start();
    paths: [..] string;
    for root: roots {
        scan_directory := resolve_path(root, cwd);
        raw_paths := collect_jai_files(scan_directory);
        for raw_path: raw_paths {
            add_unique_path(*paths, resolve_path(raw_path, cwd));
        }
    }
    if PROGRAMMING_PROFILE_ENABLED tool_profile_collect_seconds += profile_seconds_since(profile_start);

    for path: paths {
        profile_start = profile_timer_start();
        source, read_ok := read_entire_file(path);
        if PROGRAMMING_PROFILE_ENABLED tool_profile_read_seconds += profile_seconds_since(profile_start);
        if !read_ok {
            log_error("Could not read '%'", path);
            ok = false;
            continue;
        }

        root: *Node;
        if path_equal(path, target_path) {
            profile_start = profile_timer_start();
            parse_result := parse(source);
            if PROGRAMMING_PROFILE_ENABLED tool_profile_target_parse_seconds += profile_seconds_since(profile_start);
            if !parse_result.success {
                log_error("Parser failed for '%' at %:%: %", path, parse_result.error.span.line, parse_result.error.span.column, parse_result.error.message);
                ok = false;
                continue;
            }
            root = parse_result.root;
            if PROGRAMMING_PROFILE_ENABLED tool_profile_full_parse_file_count += 1;
        } else {
            profile_start = profile_timer_start();
            summary_root, summary_ok := summarize_file_items(source);
            if PROGRAMMING_PROFILE_ENABLED tool_profile_summary_parse_seconds += profile_seconds_since(profile_start);
            if !summary_ok {
                log_error("Summary parse failed for '%'", path);
                ok = false;
                continue;
            }
            root = summary_root;
            if PROGRAMMING_PROFILE_ENABLED {
                tool_profile_summary_file_count += 1;
                tool_profile_summary_declaration_count += summary_root.declarations.count;
            }
        }

        file: Programming_File;
        file.path = path;
        file.source = source;
        file.root = root;
        array_add(*files, file);

        input: Resolver_Input_File;
        input.path = path;
        input.root = root;
        array_add(*inputs, input);
    }

    return files, inputs, ok;
}

load_indexed_project :: (options: Program_Options) -> (Indexed_Project, bool) {
    project: Indexed_Project;
    ok := true;

    cwd := get_working_directory();
    roots: [..] string;
    array_add(*roots, options.directory);
    if options.include_jai_modules array_add(*roots, options.jai_modules_directory);

    profile_start: Apollo_Time;
    profile_start = profile_timer_start();
    paths: [..] string;
    for root: roots {
        scan_directory := resolve_path(root, cwd);
        raw_paths := collect_jai_files(scan_directory);
        for raw_path: raw_paths {
            add_unique_path(*paths, resolve_path(raw_path, cwd));
        }
    }
    if PROGRAMMING_PROFILE_ENABLED tool_profile_collect_seconds += profile_seconds_since(profile_start);

    for path: paths {
        profile_start = profile_timer_start();
        source, read_ok := read_entire_file(path);
        if PROGRAMMING_PROFILE_ENABLED tool_profile_read_seconds += profile_seconds_since(profile_start);
        if !read_ok {
            log_error("Could not read '%'", path);
            ok = false;
            continue;
        }

        profile_start = profile_timer_start();
        summary_root, summary_ok := summarize_file_items(source);
        if PROGRAMMING_PROFILE_ENABLED tool_profile_summary_parse_seconds += profile_seconds_since(profile_start);
        if !summary_ok {
            log_error("Summary parse failed for '%'", path);
            ok = false;
            continue;
        }

        file: Programming_File;
        file.path = path;
        file.source = source;
        file.root = summary_root;
        array_add(*project.files, file);

        if PROGRAMMING_PROFILE_ENABLED {
            tool_profile_summary_file_count += 1;
            tool_profile_summary_declaration_count += summary_root.declarations.count;
        }
        for declaration: summary_root.declarations {
            if declaration == null || declaration.name.count == 0 continue;

            indexed: Indexed_Declaration;
            indexed.name = declaration.name;
            indexed.file_path = path;
            indexed.node = declaration;
            array_add(*project.declarations, indexed);
        }
    }

    return project, ok;
}

load_source_files :: (options: Program_Options) -> ([..] Programming_File, bool) {
    files: [..] Programming_File;
    ok := true;

    cwd := get_working_directory();
    roots: [..] string;
    array_add(*roots, options.directory);
    if options.include_jai_modules array_add(*roots, options.jai_modules_directory);

    profile_start: Apollo_Time;
    profile_start = profile_timer_start();
    paths: [..] string;
    for root: roots {
        scan_directory := resolve_path(root, cwd);
        raw_paths := collect_jai_files(scan_directory);
        for raw_path: raw_paths {
            add_unique_path(*paths, resolve_path(raw_path, cwd));
        }
    }
    if PROGRAMMING_PROFILE_ENABLED tool_profile_collect_seconds += profile_seconds_since(profile_start);

    for path: paths {
        profile_start = profile_timer_start();
        source, read_ok := read_entire_file(path);
        if PROGRAMMING_PROFILE_ENABLED tool_profile_read_seconds += profile_seconds_since(profile_start);
        if !read_ok {
            log_error("Could not read '%'", path);
            ok = false;
            continue;
        }

        file: Programming_File;
        file.path = path;
        file.source = source;
        file.root = null;
        array_add(*files, file);
    }

    return files, ok;
}

source_position_for_line_column :: (source: string, line: int, column: int) -> int {
    if line <= 0 || column <= 0 return -1;

    i := 0;
    current_line := 1;
    while i < source.count && current_line < line {
        if source[i] == #char "\n" {
            current_line += 1;
        }
        i += 1;
    }

    if current_line != line return -1;

    position := i + column - 1;
    if position < 0 || position > source.count return -1;
    return position;
}

identifier_at_location :: (source: string, line: int, column: int) -> string {
    position := source_position_for_line_column(source, line, column);
    if position < 0 || position >= source.count return "";

    if !programming_is_identifier_continue(source[position]) {
        if position > 0 && programming_is_identifier_continue(source[position - 1]) position -= 1;
        else return "";
    }

    start := position;
    while start > 0 && programming_is_identifier_continue(source[start - 1]) start -= 1;

    end := position + 1;
    while end < source.count && programming_is_identifier_continue(source[end]) end += 1;

    return source_slice(source, start, end - start);
}

find_unique_indexed_declaration :: (project: Indexed_Project, name: string) -> (Indexed_Declaration, bool) {
    found: Indexed_Declaration;
    count := 0;

    for declaration: project.declarations {
        if declaration.name != name continue;
        found = declaration;
        count += 1;
        if count > 1 return found, false;
    }

    return found, count == 1;
}

source_line_column_for_position :: (source: string, position: int) -> (line: int, column: int) {
    line := 1;
    column := 1;
    i := 0;
    while i < source.count && i < position {
        if source[i] == #char "\n" {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
        i += 1;
    }

    return line, column;
}

skip_source_whitespace :: (source: string, i: *int) {
    while i.* < source.count {
        c := source[i.*];
        if c != #char " " && c != #char "\t" && c != #char "\r" && c != #char "\n" break;
        i.* += 1;
    }
}

find_declaration_by_name_in_source :: (source: string, name: string) -> *Node {
    if name.count == 0 return null;

    i := 0;
    while i <= source.count - name.count {
        if source[i] != name[0] {
            i += 1;
            continue;
        }

        matched := true;
        for j: 1..name.count-1 {
            if source[i + j] != name[j] {
                matched = false;
                break;
            }
        }

        if matched {
            before_ok := i == 0 || !programming_is_identifier_continue(source[i - 1]);
            after_index := i + name.count;
            after_ok := after_index >= source.count || !programming_is_identifier_continue(source[after_index]);
            if before_ok && after_ok {
                cursor := after_index;
                skip_source_whitespace(source, *cursor);

                if cursor < source.count && source[cursor] == #char ":" {
                    line, column := source_line_column_for_position(source, i);
                    kind := Node_Kind.GLOBAL_TYPED_DECL;
                    if cursor + 1 < source.count && source[cursor + 1] == #char ":" kind = .CONST_DECL;

                    node := make_summary_node(kind, .{ start_position_in_input = i, count = name.count, line = line, column = column });
                    node.name = name;
                    return node;
                }
            }
        }

        i += 1;
    }

    return null;
}

find_unique_source_declaration :: (files: [] Programming_File, name: string) -> (Indexed_Declaration, bool) {
    found: Indexed_Declaration;
    count := 0;

    for file: files {
        node := find_declaration_by_name_in_source(file.source, name);
        if node == null continue;

        found = .{ name = name, file_path = file.path, node = node };
        count += 1;
        if count > 1 return found, false;
    }

    return found, count == 1;
}

server_resolve_definition_response :: (request: Location_Request, options: Program_Options) -> string {
    query_options := options;
    query_options.request = request;

    files, inputs, project_ok := load_project_for_find_def(query_options);
    if !project_ok return "error,definition,resolver_load_failed";

    resolver := resolve_project_symbols_for_file(inputs, request.filename);
    symbol := find_symbol_for_request(resolver, request);
    if symbol == null || symbol.declaration_node == null return "error,definition,no_symbol";

    return tprint("ok,definition,%@%:%", symbol.file_path, symbol.declaration_node.span.line, symbol.declaration_node.span.column);
}

collect_identifier_occurrences :: (source: string, name: string) -> [..] Programming_Edit {
    edits: [..] Programming_Edit;
    if name.count == 0 return edits;

    i := 0;
    while i <= source.count - name.count {
        if source[i] != name[0] {
            i += 1;
            continue;
        }

        matched := true;
        for j: 1..name.count-1 {
            if source[i + j] != name[j] {
                matched = false;
                break;
            }
        }

        if matched {
            before_ok := i == 0 || !programming_is_identifier_continue(source[i - 1]);
            after_index := i + name.count;
            after_ok := after_index >= source.count || !programming_is_identifier_continue(source[after_index]);
            if before_ok && after_ok {
                array_add(*edits, .{ start = i, count = name.count });
                i += name.count;
                continue;
            }
        }

        i += 1;
    }

    return edits;
}

count_identifier_occurrences_by_area :: (files: [] Programming_File, name: string, options: Program_Options) -> (total_edits: int, project_edits: int, module_edits: int, files_with_edits: int) {
    total_edits := 0;
    project_edits := 0;
    module_edits := 0;
    files_with_edits := 0;

    for file: files {
        edits := collect_identifier_occurrences(file.source, name);
        if edits.count == 0 continue;

        total_edits += edits.count;
        files_with_edits += 1;
        if path_is_in_jai_modules(file.path, options) {
            module_edits += edits.count;
        } else {
            project_edits += edits.count;
        }
    }

    return total_edits, project_edits, module_edits, files_with_edits;
}

promote_identifier_candidates :: (files: *[..] Programming_File, inputs: *[..] Resolver_Input_File, options: Program_Options, primary_name: string, secondary_name: string) -> ([..] string, int, int, bool) {
    candidate_paths: [..] string;
    ok := true;
    scanned_files := 0;
    promoted_files := 0;

    cwd := get_working_directory();
    target_path := resolve_path(options.request.filename, cwd);

    for i: 0..files.*.count-1 {
        file := files.*[i];
        scanned_files += 1;

        is_candidate := path_equal(file.path, target_path);
        if !is_candidate {
            is_candidate = source_contains_identifier(file.source, primary_name) ||
                           (secondary_name.count > 0 && source_contains_identifier(file.source, secondary_name));
        }

        if !is_candidate continue;
        promoted_files += 1;

        if !path_equal(file.path, target_path) {
            parse_result := parse(file.source);
            if !parse_result.success {
                log_error("Parser failed for candidate '%' at %:%: %", file.path, parse_result.error.span.line, parse_result.error.span.column, parse_result.error.message);
                ok = false;
                continue;
            }

            files.*[i].root = parse_result.root;
            inputs.*[i].root = parse_result.root;
        }

        add_unique_path(*candidate_paths, file.path);
    }

    return candidate_paths, scanned_files, promoted_files, ok;
}

source_contains_identifier :: (source: string, name: string) -> bool {
    if name.count == 0 return false;

    simple_identifier := true;
    if !programming_is_identifier_start(name[0]) {
        simple_identifier = false;
    } else {
        for i: 1..name.count-1 {
            if !programming_is_identifier_continue(name[i]) {
                simple_identifier = false;
                break;
            }
        }
    }

    i := 0;
    while i <= source.count - name.count {
        if source[i] != name[0] {
            i += 1;
            continue;
        }

        matched := true;
        for j: 1..name.count-1 {
            if source[i + j] != name[j] {
                matched = false;
                break;
            }
        }

        if matched {
            if !simple_identifier return true;

            before_ok := i == 0 || !programming_is_identifier_continue(source[i - 1]);
            after_index := i + name.count;
            after_ok := after_index >= source.count || !programming_is_identifier_continue(source[after_index]);
            if before_ok && after_ok return true;
        }

        i += 1;
    }

    return false;
}

summarize_file_items :: (source: string) -> (*Node, bool) {
    summary_tokens := lex_summary_tokens(source);
    root := summarize_tokens_items(summary_tokens);
    array_free(summary_tokens);
    return root, true;
}

lex_summary_tokens :: (source: string) -> [..] Token {
    tokens: [..] Token;

    i := 0;
    line := 1;
    column := 1;
    while i < source.count {
        c := source[i];

        if c == #char " " || c == #char "\t" || c == #char "\r" || c == #char "\n" {
            advance_summary_char(source, *i, *line, *column);
            continue;
        }

        if c == #char "/" && i + 1 < source.count && source[i + 1] == #char "/" {
            advance_summary_char(source, *i, *line, *column);
            advance_summary_char(source, *i, *line, *column);
            while i < source.count && source[i] != #char "\n" advance_summary_char(source, *i, *line, *column);
            continue;
        }

        if c == #char "/" && i + 1 < source.count && source[i + 1] == #char "*" {
            advance_summary_char(source, *i, *line, *column);
            advance_summary_char(source, *i, *line, *column);
            while i + 1 < source.count {
                if source[i] == #char "*" && source[i + 1] == #char "/" {
                    advance_summary_char(source, *i, *line, *column);
                    advance_summary_char(source, *i, *line, *column);
                    break;
                }
                advance_summary_char(source, *i, *line, *column);
            }
            continue;
        }

        if c == #char "\"" {
            skip_summary_string(source, *i, *line, *column);
            continue;
        }

        if c == #char "#" && source_starts_with_at(source, i, "#string") {
            skip_summary_raw_string(source, *i, *line, *column);
            continue;
        }

        if c == #char "`" {
            advance_summary_char(source, *i, *line, *column);
            continue;
        }

        if c == #char "{" {
            skip_summary_brace_body(source, *i, *line, *column, *tokens);
            continue;
        }

        if programming_is_identifier_start(c) {
            start := i;
            start_line := line;
            start_column := column;
            advance_summary_char(source, *i, *line, *column);
            while i < source.count && programming_is_identifier_continue(source[i]) advance_summary_char(source, *i, *line, *column);
            text := source_slice(source, start, i - start);
            kind := summary_keyword_kind(text);
            array_add(*tokens, .{ kind = kind, text = text, span = .{ start_position_in_input = start, count = i - start, line = start_line, column = start_column } });
            continue;
        }

        kind := Token_Kind.INVALID;
        count := 1;
        start := i;
        start_line := line;
        start_column := column;
        if c == #char "(" kind = .OPEN_PAREN;
        else if c == #char ")" kind = .CLOSE_PAREN;
        else if c == #char "{" kind = .OPEN_BRACE;
        else if c == #char "}" kind = .CLOSE_BRACE;
        else if c == #char "[" kind = .OPEN_BRACKET;
        else if c == #char "]" kind = .CLOSE_BRACKET;
        else if c == #char "," kind = .COMMA;
        else if c == #char ";" kind = .SEMICOLON;
        else if c == #char ":" {
            if i + 1 < source.count && source[i + 1] == #char ":" {
                kind = .COLON_COLON;
                count = 2;
            } else {
                kind = .COLON;
            }
        }

        if kind != .INVALID {
            array_add(*tokens, .{ kind = kind, text = source_slice(source, start, count), span = .{ start_position_in_input = start, count = count, line = start_line, column = start_column } });
        }
        for 0..count-1 advance_summary_char(source, *i, *line, *column);
    }

    array_add(*tokens, .{ kind = .EOF, text = "", span = .{ start_position_in_input = source.count, count = 0, line = line, column = column } });
    return tokens;
}

skip_summary_brace_body :: (source: string, i: *int, line: *int, column: *int, tokens: *[..] Token) {
    open_start := i.*;
    open_line := line.*;
    open_column := column.*;
    array_add(tokens, .{ kind = .OPEN_BRACE, text = source_slice(source, open_start, 1), span = .{ start_position_in_input = open_start, count = 1, line = open_line, column = open_column } });
    skip_summary_brace_body_without_tokens(source, i, line, column);

    close_position := i.* - 1;
    array_add(tokens, .{ kind = .CLOSE_BRACE, text = source_slice(source, close_position, 1), span = .{ start_position_in_input = close_position, count = 1, line = line.*, column = column.* } });
}

summary_keyword_kind :: (text: string) -> Token_Kind {
    if text == "struct" return .STRUCT;
    if text == "union" return .UNION;
    if text == "enum" return .ENUM;
    if text == "enum_flags" return .ENUM_FLAGS;
    return .IDENTIFIER;
}

skip_summary_string :: (source: string, i: *int, line: *int, column: *int) {
    advance_summary_char(source, i, line, column);
    while i.* < source.count {
        if source[i.*] == #char "\\" {
            advance_summary_char(source, i, line, column);
            if i.* < source.count advance_summary_char(source, i, line, column);
            continue;
        }

        if source[i.*] == #char "\"" {
            advance_summary_char(source, i, line, column);
            return;
        }
        advance_summary_char(source, i, line, column);
    }
}

skip_summary_brace_body_without_tokens :: (source: string, i: *int, line: *int, column: *int) {
    advance_summary_char(source, i, line, column);

    depth := 1;
    while i.* < source.count {
        c := source[i.*];

        if c == #char "/" && i.* + 1 < source.count && source[i.* + 1] == #char "/" {
            advance_summary_char(source, i, line, column);
            advance_summary_char(source, i, line, column);
            while i.* < source.count && source[i.*] != #char "\n" advance_summary_char(source, i, line, column);
            continue;
        }

        if c == #char "/" && i.* + 1 < source.count && source[i.* + 1] == #char "*" {
            advance_summary_char(source, i, line, column);
            advance_summary_char(source, i, line, column);
            while i.* + 1 < source.count {
                if source[i.*] == #char "*" && source[i.* + 1] == #char "/" {
                    advance_summary_char(source, i, line, column);
                    advance_summary_char(source, i, line, column);
                    break;
                }
                advance_summary_char(source, i, line, column);
            }
            continue;
        }

        if c == #char "\"" {
            skip_summary_string(source, i, line, column);
            continue;
        }

        if c == #char "#" && source_starts_with_at(source, i.*, "#string") {
            skip_summary_raw_string(source, i, line, column);
            continue;
        }

        if c == #char "{" {
            depth += 1;
            advance_summary_char(source, i, line, column);
            continue;
        }

        if c == #char "}" {
            depth -= 1;
            advance_summary_char(source, i, line, column);
            if depth == 0 return;
            continue;
        }

        advance_summary_char(source, i, line, column);
    }
}

skip_summary_raw_string :: (source: string, i: *int, line: *int, column: *int) {
    for 0..6 advance_summary_char(source, i, line, column);
    while i.* < source.count && (source[i.*] == #char " " || source[i.*] == #char "\t") advance_summary_char(source, i, line, column);

    delimiter_start := i.*;
    while i.* < source.count && programming_is_identifier_continue(source[i.*]) advance_summary_char(source, i, line, column);
    delimiter := source_slice(source, delimiter_start, i.* - delimiter_start);

    while i.* < source.count && source[i.*] != #char "\n" advance_summary_char(source, i, line, column);
    if i.* < source.count advance_summary_char(source, i, line, column);

    while i.* < source.count {
        while i.* < source.count && (source[i.*] == #char " " || source[i.*] == #char "\t") advance_summary_char(source, i, line, column);
        if source_starts_with_at(source, i.*, delimiter) {
            for 0..delimiter.count-1 advance_summary_char(source, i, line, column);
            return;
        }
        while i.* < source.count && source[i.*] != #char "\n" advance_summary_char(source, i, line, column);
        if i.* < source.count advance_summary_char(source, i, line, column);
    }
}

source_starts_with_at :: inline (source: string, start: int, text: string) -> bool {
    if start < 0 || text.count < 0 return false;
    if start + text.count > source.count return false;

    for i: 0..text.count-1 {
        if source[start + i] != text[i] return false;
    }

    return true;
}

advance_summary_char :: inline (source: string, i: *int, line: *int, column: *int) {
    if i.* >= source.count return;

    if source[i.*] == #char "\n" {
        line.* += 1;
        column.* = 1;
    } else {
        column.* += 1;
    }
    i.* += 1;
}

source_slice :: inline (source: string, start: int, count: int) -> string {
    result: string;
    result.data = source.data + start;
    result.count = count;
    return result;
}

summarize_tokens_items :: (tokens: [] Token) -> *Node {
    root := make_summary_node(.FILE, .{});

    depth := 0;
    i := 0;
    while i < tokens.count {
        token := tokens[i];

        if token.kind == .OPEN_PAREN || token.kind == .OPEN_BRACE || token.kind == .OPEN_BRACKET {
            depth += 1;
            i += 1;
            continue;
        }

        if token.kind == .CLOSE_PAREN || token.kind == .CLOSE_BRACE || token.kind == .CLOSE_BRACKET {
            if depth > 0 depth -= 1;
            i += 1;
            continue;
        }

        if depth == 0 && token.kind == .IDENTIFIER {
            next_kind := token_kind_at(tokens, i + 1);
            if next_kind == .COLON_COLON || next_kind == .COLON || next_kind == .COMMA {
                names: [..] Token;
                array_add(*names, token);
                scan := i;

                while token_kind_at(tokens, scan + 1) == .COMMA {
                    scan += 2;
                    if token_kind_at(tokens, scan) != .IDENTIFIER break;
                    array_add(*names, tokens[scan]);
                }

                scan += 1;
                while token_kind_at(tokens, scan) == .COMMA {
                    scan += 1;
                    if token_kind_at(tokens, scan) != .IDENTIFIER break;
                    array_add(*names, tokens[scan]);
                    scan += 1;
                }

                separator := token_kind_at(tokens, scan);
                if separator == .COLON_COLON || separator == .COLON {
                    kind := summary_declaration_kind(tokens, scan);
                    for name: names {
                        decl := make_summary_node(kind, name.span);
                        decl.name = name.text;
                        array_add(*root.declarations, decl);
                    }
                    i = skip_top_level_summary_declaration(tokens, scan + 1);
                    continue;
                }
            }
        }

        i += 1;
    }

    return root;
}

summary_declaration_kind :: (tokens: [] Token, separator_index: int) -> Node_Kind {
    if token_kind_at(tokens, separator_index) == .COLON_COLON {
        after := separator_index + 1;
        if token_kind_at(tokens, after) == .STRUCT || token_kind_at(tokens, after) == .UNION return .STRUCT_DECL;
        if token_kind_at(tokens, after) == .ENUM || token_kind_at(tokens, after) == .ENUM_FLAGS return .ENUM_DECL;

        while token_kind_at(tokens, after) == .IDENTIFIER {
            if tokens[after].text != "inline" && tokens[after].text != "no_inline" break;
            after += 1;
        }

        if token_kind_at(tokens, after) == .OPEN_PAREN return .FUNCTION;
        return .CONST_DECL;
    }

    return .GLOBAL_TYPED_DECL;
}

skip_top_level_summary_declaration :: (tokens: [] Token, start_index: int) -> int {
    depth := 0;
    i := start_index;
    while i < tokens.count {
        kind := tokens[i].kind;

        if kind == .OPEN_PAREN || kind == .OPEN_BRACKET {
            depth += 1;
        } else if kind == .CLOSE_PAREN || kind == .CLOSE_BRACKET {
            if depth > 0 depth -= 1;
        } else if kind == .OPEN_BRACE {
            return skip_summary_balanced(tokens, i, .OPEN_BRACE, .CLOSE_BRACE);
        } else if depth == 0 && (kind == .SEMICOLON || kind == .EOF) {
            return i + 1;
        }

        i += 1;
    }

    return i;
}

skip_summary_balanced :: (tokens: [] Token, open_index: int, open_kind: Token_Kind, close_kind: Token_Kind) -> int {
    depth := 1;
    i := open_index + 1;
    while i < tokens.count && depth > 0 {
        if tokens[i].kind == open_kind depth += 1;
        else if tokens[i].kind == close_kind depth -= 1;
        i += 1;
    }
    return i;
}

token_kind_at :: (tokens: [] Token, index: int) -> Token_Kind {
    if index < 0 || index >= tokens.count return .EOF;
    return tokens[index].kind;
}

make_summary_node :: (kind: Node_Kind, span: Source_Span) -> *Node {
    node := New(Node);
    node.kind = kind;
    node.span = span;
    return node;
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

position_key :: (file_path: string, line: int, column: int) -> string {
    return tprint("%@%:%", file_path, line, column);
}

index_add_span :: (index: *Position_Index, file_path: string, span: Source_Span, symbol: *Resolver_Symbol) {
    if symbol == null || file_path.count == 0 || span.count <= 0 return;

    for column: span.column..span.column + span.count - 1 {
        key := position_key(file_path, span.line, column);
        found, _ := table_find(*index.symbols_by_position, key);
        if !found table_add(*index.symbols_by_position, key, symbol);
    }
}

build_position_index :: (resolver: Resolver_Result) -> Position_Index {
    index: Position_Index;

    for symbol: resolver.symbols {
        if symbol == null || symbol.declaration_node == null continue;
        index_add_span(*index, symbol.file_path, symbol.declaration_node.span, symbol);
        index_add_reference_count(*index, symbol, 1);
        index_add_name_count(*index.symbol_names, symbol.name);
    }

    for reference: resolver.references {
        if reference.node == null continue;
        index_add_span(*index, reference.file_path, reference.node.span, reference.symbol);
        index_add_reference_count(*index, reference.symbol, 1);
        index_add_name_count(*index.reference_names, reference.name);
    }

    return index;
}

index_add_reference_count :: (index: *Position_Index, symbol: *Resolver_Symbol, count: int) {
    if symbol == null return;

    for * entry: index.reference_counts {
        if entry.symbol == symbol {
            entry.count += count;
            return;
        }
    }

    array_add(*index.reference_counts, .{ symbol = symbol, count = count });
}

index_add_name_count :: (table: *Table(string, int), name: string) {
    if name.count == 0 return;

    found, count := table_find(table, name);
    if found {
        table_set(table, name, count + 1);
    } else {
        table_add(table, name, 1);
    }
}

index_has_name :: (table: *Table(string, int), name: string) -> bool {
    found, _ := table_find(table, name);
    return found;
}

index_reference_count :: (index: Position_Index, symbol: *Resolver_Symbol) -> int {
    if symbol == null return 0;

    for entry: index.reference_counts {
        if entry.symbol == symbol return entry.count;
    }

    return 0;
}

check_rename_conflicts_indexed_quiet :: (index: *Position_Index, resolver: Resolver_Result, symbol: *Resolver_Symbol, new_name: string) -> int {
    if symbol == null || new_name == symbol.name return 0;

    has_symbol_name := index_has_name(*index.symbol_names, new_name);
    has_reference_name := index_has_name(*index.reference_names, new_name);
    if !has_symbol_name && !has_reference_name return 0;

    return check_rename_conflicts_quiet(resolver, symbol, new_name);
}

build_query_state :: (options: Program_Options) -> (Query_State, bool) {
    state: Query_State;

    files, inputs, project_ok := load_project_for_find_def(options);
    if !project_ok return state, false;

    seed_resolver := resolve_project_symbols_for_file(inputs, options.request.filename);
    seed_symbol := find_symbol_for_request(seed_resolver, options.request);
    if seed_symbol == null {
        log_error("No symbol found at %@%:%", options.request.filename, options.request.line, options.request.column);
        return state, false;
    }

    candidate_paths, scanned_files, promoted_files, promote_ok := promote_identifier_candidates(*files, *inputs, options, seed_symbol.name, options.new_name);
    if !promote_ok return state, false;

    resolver := resolve_project_symbols_for_files(inputs, candidate_paths);
    symbol := find_symbol_for_request(resolver, options.request);
    if symbol == null {
        log_error("No symbol found in warmed resolver at %@%:%", options.request.filename, options.request.line, options.request.column);
        return state, false;
    }

    state.files = files;
    state.inputs = inputs;
    state.resolver = resolver;
    state.index = build_position_index(resolver);
    state.symbol = symbol;
    state.request_key = position_key(options.request.filename, options.request.line, options.request.column);
    state.scanned_files = scanned_files;
    state.promoted_files = promoted_files;

    return state, true;
}

find_symbol_for_request_indexed :: (index: Position_Index, request_key: string) -> *Resolver_Symbol {
    found, symbol := table_find(*index.symbols_by_position, request_key);
    if !found return null;
    return symbol;
}

reference_count_for_symbol_in_project :: (resolver: Resolver_Result, symbol: *Resolver_Symbol) -> int {
    if symbol == null return 0;

    count := 0;
    if symbol.declaration_node != null count += 1;

    for reference: resolver.references {
        if reference.symbol == symbol count += 1;
    }

    return count;
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

file_list_contains_path :: (files: [] Programming_File, path: string) -> bool {
    for file: files {
        if path_equal(file.path, path) return true;
    }
    return false;
}

collect_rename_files :: (files: [] Programming_File, options: Program_Options) -> [..] Programming_File {
    result: [..] Programming_File;
    project_directory := resolve_path(options.directory, get_working_directory());
    modules_directory := resolve_path(options.jai_modules_directory, get_working_directory());

    for file: files {
        if !path_is_under_directory(file.path, project_directory) continue;
        if options.include_jai_modules && path_is_under_directory(file.path, modules_directory) continue;
        array_add(*result, file);
    }

    return result;
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

check_rename_conflicts :: (resolver: Resolver_Result, symbol: *Resolver_Symbol, new_name: string, rename_files: [] Programming_File) -> int {
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
        if !file_list_contains_path(rename_files, reference.file_path) continue;

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

check_rename_conflicts_quiet :: (resolver: Resolver_Result, symbol: *Resolver_Symbol, new_name: string) -> int {
    if symbol == null || new_name == symbol.name return 0;

    warnings := 0;

    same_scope_symbol := find_symbol_in_scope(symbol.scope, new_name);
    if same_scope_symbol != null && same_scope_symbol != symbol warnings += 1;

    if symbol.scope != null {
        visible_symbol := find_symbol(symbol.scope.parent, new_name);
        if visible_symbol != null && visible_symbol != symbol warnings += 1;
    }

    for reference: resolver.references {
        if reference.node == null || reference.scope == null continue;

        if reference.symbol == symbol {
            visible_symbol := find_symbol(reference.scope, new_name);
            if visible_symbol != null && visible_symbol != symbol warnings += 1;
            continue;
        }

        if reference.name != new_name continue;
        if !scope_is_or_descends_from(reference.scope, symbol.scope) continue;

        if reference.scope == symbol.scope && symbol.declaration_node != null &&
           reference.node.span.start_position_in_input < symbol.declaration_node.span.start_position_in_input {
            continue;
        }

        warnings += 1;
    }

    return warnings;
}

find_symbol_for_request :: (resolver: Resolver_Result, request: Location_Request) -> *Resolver_Symbol {
    return find_symbol_at_position_in_file(resolver, request.filename, request.line, request.column);
}

#if PROGRAMMING_PROFILE_ENABLED {
    print_tool_profile_header :: () {
        log("tool_profile,phase,total_ms");
    }

    print_tool_profile_row :: (phase: string, seconds: float64) {
        log("tool_profile,%,%", phase, seconds * 1000.0);
    }

    print_tool_profile_count :: (name: string, value: int) {
        log("tool_profile_count,%,%", name, value);
    }
} else {
    print_tool_profile_header :: () {
    }

    print_tool_profile_row :: (phase: string, seconds: float64) {
    }

    print_tool_profile_count :: (name: string, value: int) {
    }
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

    log("Rename Preview");
    log(" ");
    log("  Symbol:      '%'", symbol.name);
    log("  New name:    '%'", options.new_name);
    log("  Declared at: %@%:%", symbol.file_path, symbol.declaration_node.span.line, symbol.declaration_node.span.column);
    log(" ");

    rename_files := collect_rename_files(files, options);
    print_usages(rename_files, resolver, symbol);
    warnings := check_rename_conflicts(resolver, symbol, options.new_name, rename_files);
    module_edits := 0;
    modules_directory := jai_modules_directory_for_options(options);
    for file: rename_files {
        edits := collect_edits_for_file(resolver, symbol, file.path);
        if edits.count == 0 continue;
        if path_is_in_jai_modules(file.path, options) module_edits += edits.count;
    }

    if module_edits > 0 {
        log("Jai Modules Rename Safety");
        log(" ");
        log("  This rename would touch % occurrence(s) under:", module_edits);
        log("  %", modules_directory);
        log(" ");
        log("  Preview is allowed, but applying this rename requires explicit confirmation.");
        log(" ");
    }

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

    if module_edits > 0 && !options.allow_jai_modules_rename {
        log("Rename not applied.");
        log(" ");
        log("This rename would modify % occurrence(s) in the Jai modules directory:", module_edits);
        log("  %", modules_directory);
        log(" ");
        log("Run again with -allow_jai_modules_rename if you really want to make this change.");
        return false;
    }

    total_edits := 0;
    for file: rename_files {
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
    log("  -allow_jai_modules_rename");
    log("                       Allow -y rename to modify files under the Jai modules directory.");
    log("  -full_project        Use the full parser-backed project load for diagnostics.");
    if PROGRAMMING_PROFILE_ENABLED log("  -profile     Print phase timings for the query pipeline.");
}

#scope_export

print_bench_usage :: () {
    log("Usage:");
    log("  tbx_programming bench <file>@<line>:<col> [-dir <path>] [-n iterations] [-rename_name <name>]");
}

run_bench :: (options: Program_Options, iterations: int) -> bool {
    bench_options := options;
    bench_iterations := iterations;
    if bench_iterations <= 0 bench_iterations = 1000;
    if bench_options.new_name.count == 0 bench_options.new_name = "renamed_symbol";
    if !is_valid_identifier(bench_options.new_name) {
        log_error("Rename benchmark name '%' is not a valid simple Jai identifier.", bench_options.new_name);
        return false;
    }

    reset_tool_profile_counts();
    index_start := current_time_monotonic();

    state, state_ok := build_query_state(bench_options);
    if !state_ok return false;
    index_seconds := to_float64_seconds(current_time_monotonic() - index_start);

    checksum := 0;

    start := current_time_monotonic();
    for 0..bench_iterations-1 {
        found := find_symbol_for_request_indexed(state.index, state.request_key);
        if found == null return false;
        if found.declaration_node != null checksum += found.declaration_node.span.line + found.declaration_node.span.column;
    }
    definition_seconds := to_float64_seconds(current_time_monotonic() - start);

    start = current_time_monotonic();
    for 0..bench_iterations-1 {
        checksum += index_reference_count(state.index, state.symbol);
    }
    references_seconds := to_float64_seconds(current_time_monotonic() - start);

    start = current_time_monotonic();
    for 0..bench_iterations-1 {
        warnings := check_rename_conflicts_indexed_quiet(*state.index, state.resolver, state.symbol, bench_options.new_name);
        edit_count := index_reference_count(state.index, state.symbol);
        checksum += warnings + edit_count;
    }
    rename_seconds := to_float64_seconds(current_time_monotonic() - start);

    log("bench,file=%,iterations=%,checksum=%", bench_options.request.filename, bench_iterations, checksum);
    log("bench_count,summary_files,%", tool_profile_summary_file_count);
    log("bench_count,full_parse_files,%", tool_profile_full_parse_file_count);
    log("bench_count,summary_declarations,%", tool_profile_summary_declaration_count);
    log("bench_count,candidate_scanned_files,%", state.scanned_files);
    log("bench_count,candidate_promoted_files,%", state.promoted_files);
    log("bench,phase,total_ms,per_iter_ms");
    log("bench,index_build,%,%", index_seconds * 1000.0, index_seconds * 1000.0);
    log("bench,definition_warm,%,%", definition_seconds * 1000.0, definition_seconds * 1000.0 / cast(float64) bench_iterations);
    log("bench,references_warm,%,%", references_seconds * 1000.0, references_seconds * 1000.0 / cast(float64) bench_iterations);
    log("bench,rename_preview_warm,%,%", rename_seconds * 1000.0, rename_seconds * 1000.0 / cast(float64) bench_iterations);

    return true;
}

programming_run_bench_cli :: (args: [] string) -> bool {
    if args.count < 3 {
        print_bench_usage();
        return false;
    }

    cwd := get_working_directory();

    options: Program_Options;
    options.directory = cwd;
    options.include_jai_modules = true;
    options.jai_modules_directory = DEFAULT_JAI_MODULES_DIRECTORY;
    options.mode = .RENAME;
    options.new_name = "renamed_symbol";

    loc_ok, filename, line, col := parse_location(args[2], cwd);
    if !loc_ok {
        log_error("Invalid location. Usage: <file>@<line>:<col>");
        return false;
    }
    options.request = .{ filename = filename, line = line, column = col };

    iterations := 1000;
    i := 3;
    while i < args.count {
        arg := args[i];

        if arg == "-dir" {
            i += 1;
            if i >= args.count {
                log_error("-dir requires a path.");
                return false;
            }
            options.directory = resolve_path(args[i], cwd);
        } else if arg == "-n" || arg == "--iterations" {
            i += 1;
            if i >= args.count {
                log_error("% requires an iteration count.", arg);
                return false;
            }

            parsed, ok, _ := string_to_int(args[i]);
            if !ok || parsed <= 0 {
                log_error("Invalid iteration count: %.", args[i]);
                return false;
            }
            iterations = parsed;
        } else if arg == "-rename_name" || arg == "--rename-name" {
            i += 1;
            if i >= args.count {
                log_error("% requires a new name.", arg);
                return false;
            }
            options.new_name = args[i];
        } else if arg == "-jai_modules" {
            i += 1;
            if i >= args.count {
                log_error("-jai_modules requires a path.");
                return false;
            }
            options.include_jai_modules = true;
            options.jai_modules_directory = resolve_path(args[i], cwd);
        } else if arg == "-no_jai_modules" {
            options.include_jai_modules = false;
        } else if arg == "-allow_jai_modules_rename" {
            options.allow_jai_modules_rename = true;
        } else {
            log_error("Unknown bench argument '%'", arg);
            print_bench_usage();
            return false;
        }

        i += 1;
    }

    return run_bench(options, iterations);
}

server_read_line :: (input: Windows.HANDLE) -> (string, bool) {
    builder: String_Builder;
    read_any := false;

    while true {
        c: u8;
        did_read: Windows.DWORD;
        read_ok := Windows.ReadFile(input, *c, 1, *did_read);
        if !read_ok return builder_to_string(*builder), read_any;
        if did_read == 0 return builder_to_string(*builder), read_any;

        read_any = true;
        if c == #char "\r" continue;
        if c == #char "\n" return builder_to_string(*builder), true;
        append(*builder, c);
    }

    return builder_to_string(*builder), read_any;
}

server_flush_stdout :: () {
    Windows.FlushFileBuffers(Windows.GetStdHandle(Windows.STD_OUTPUT_HANDLE));
}

server_command_tail :: (command: string, prefix: string) -> string {
    if command.count <= prefix.count return "";
    if !begins_with(command, prefix) return "";
    if command[prefix.count] != #char " " return "";
    return trim(slice(command, prefix.count + 1, command.count - prefix.count - 1));
}

split_first_word :: (text: string) -> (string, string) {
    trimmed := trim(text);
    index := find_first(trimmed, #char " ");
    if index < 0 return trimmed, "";

    first := slice(trimmed, 0, index);
    rest := trim(slice(trimmed, index + 1, trimmed.count - index - 1));
    return first, rest;
}

server_parse_request_location :: (text: string, default_request: Location_Request, cwd: string) -> (Location_Request, bool) {
    if text.count == 0 {
        if default_request.filename.count == 0 return default_request, false;
        return default_request, true;
    }

    loc_ok, filename, line, column := parse_location(text, cwd);
    if !loc_ok return default_request, false;
    return .{ filename = filename, line = line, column = column }, true;
}

server_emit_source_query :: (files: [] Programming_File, request: Location_Request, mode: Tool_Mode, rename_name: string, start: Apollo_Time, options: Program_Options) {
    request_file := find_project_file(files, request.filename);
    if request_file == null {
        elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
        log("error,request_file_not_found,file=%,root=%,files=%,ms=%", request.filename, options.directory, files.count, elapsed_ms);
        return;
    }

    request_name := identifier_at_location(request_file.source, request.line, request.column);
    if request_name.count == 0 {
        elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
        log("error,no_identifier,ms=%", elapsed_ms);
        return;
    }

    declaration, declaration_ok := find_unique_source_declaration(files, request_name);
    if !declaration_ok {
        elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
        log("error,ambiguous_or_missing_declaration,%,ms=%", request_name, elapsed_ms);
        return;
    }

    if mode == .FIND_DEF {
        elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
        log("ok,definition,%@%:%,ms=%", declaration.file_path, declaration.node.span.line, declaration.node.span.column, elapsed_ms);
        return;
    }

    total_edits, _, _, files_with_edits := count_identifier_occurrences_by_area(files, request_name, options);

    if mode == .FIND_USAGES {
        elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
        log("ok,references,count=%,files=%,ms=%", total_edits, files_with_edits, elapsed_ms);
        return;
    }

    if mode == .RENAME {
        if !is_valid_identifier(rename_name) {
            elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
            log("error,rename_preview,invalid_name,ms=%", elapsed_ms);
            return;
        }

        warnings := 0;
        elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
        log("ok,rename_preview,edits=%,warnings=%,ms=%", total_edits, warnings, elapsed_ms);
        return;
    }

    elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
    log("error,unsupported_mode,ms=%", elapsed_ms);
}

server_source_query_response :: (files: [] Programming_File, request: Location_Request, mode: Tool_Mode, rename_name: string, options: Program_Options) -> string {
    request_file := find_project_file(files, request.filename);
    if request_file == null return tprint("error,request_file_not_found,file=%,root=%,files=%", request.filename, options.directory, files.count);

    request_name := identifier_at_location(request_file.source, request.line, request.column);
    if request_name.count == 0 return "error,no_identifier";

    declaration, declaration_ok := find_unique_source_declaration(files, request_name);

    if mode == .FIND_DEF {
        if !declaration_ok && is_builtin_type_name(request_name) return tprint("ok,no_definition,builtin_type,%", request_name);
        if !declaration_ok return server_resolve_definition_response(request, options);
        return tprint("ok,definition,%@%:%", declaration.file_path, declaration.node.span.line, declaration.node.span.column);
    }

    if !declaration_ok return tprint("error,ambiguous_or_missing_declaration,%", request_name);

    total_edits, project_edits, module_edits, files_with_edits := count_identifier_occurrences_by_area(files, request_name, options);

    if mode == .FIND_USAGES {
        return tprint("ok,references,count=%,files=%,module_edits=%", total_edits, files_with_edits, module_edits);
    }

    if mode == .RENAME {
        if !is_valid_identifier(rename_name) return "error,rename_preview,invalid_name";
        warnings := 0;
        return tprint("ok,rename_preview,edits=%,project_edits=%,module_edits=%,warnings=%", total_edits, project_edits, module_edits, warnings);
    }

    return "error,unsupported_mode";
}

programming_run_server_cli :: (args: [] string) -> bool {
    if args.count < 2 {
        log("Usage:");
        log("  tbx_programming server [-dir <path>] [-rename_name <name>]");
        log("  tbx_programming server <file>@<line>:<col> [-dir <path>] [-rename_name <name>]");
        return false;
    }

    cwd := get_working_directory();

    options: Program_Options;
    options.directory = cwd;
    options.include_jai_modules = true;
    options.jai_modules_directory = DEFAULT_JAI_MODULES_DIRECTORY;
    options.mode = .RENAME;
    options.new_name = "renamed_symbol";

    i := 2;
    if i < args.count && args[i].count > 0 && args[i][0] != #char "-" {
        loc_ok, filename, line, col := parse_location(args[i], cwd);
        if !loc_ok {
            log_error("Invalid location. Usage: <file>@<line>:<col>");
            return false;
        }
        options.request = .{ filename = filename, line = line, column = col };
        i += 1;
    }

    while i < args.count {
        arg := args[i];

        if arg == "-dir" {
            i += 1;
            if i >= args.count {
                log_error("-dir requires a path.");
                return false;
            }
            options.directory = resolve_path(args[i], cwd);
        } else if arg == "-rename_name" || arg == "--rename-name" {
            i += 1;
            if i >= args.count {
                log_error("% requires a new name.", arg);
                return false;
            }
            options.new_name = args[i];
        } else if arg == "-jai_modules" {
            i += 1;
            if i >= args.count {
                log_error("-jai_modules requires a path.");
                return false;
            }
            options.include_jai_modules = true;
            options.jai_modules_directory = resolve_path(args[i], cwd);
        } else if arg == "-no_jai_modules" {
            options.include_jai_modules = false;
        } else if arg == "-allow_jai_modules_rename" {
            options.allow_jai_modules_rename = true;
        } else {
            log_error("Unknown server argument '%'", arg);
            return false;
        }

        i += 1;
    }

    if !is_valid_identifier(options.new_name) {
        log_error("Rename server name '%' is not a valid simple Jai identifier.", options.new_name);
        return false;
    }

    reset_tool_profile_counts();
    index_start := current_time_monotonic();
    files, files_ok := load_source_files(options);
    if !files_ok return false;
    index_ms := to_float64_seconds(current_time_monotonic() - index_start) * 1000.0;

    log("ready,index_ms=%,files=%", index_ms, files.count);
    server_flush_stdout();

    response_cache: Table(string, string);

    input := Windows.GetStdHandle(Windows.STD_INPUT_HANDLE);
    while true {
        line_text, line_ok := server_read_line(input);
        if !line_ok break;
        command := trim(line_text);
        if command.count == 0 continue;

        start := current_time_monotonic();

        if command == "quit" {
            log("ok,quit");
            server_flush_stdout();
            return true;
        } else {
            found_cached, cached_response := table_find(*response_cache, command);
            if found_cached {
                elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
                log("%,ms=%", cached_response, elapsed_ms);
            } else if command == "definition" || begins_with(command, "definition ") {
                tail := server_command_tail(command, "definition");
                request, request_ok := server_parse_request_location(tail, options.request, cwd);
                response := "";
                if !request_ok response = "error,definition,missing_location";
                else response = server_source_query_response(files, request, .FIND_DEF, options.new_name, options);
                table_add(*response_cache, command, response);
                elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
                log("%,ms=%", response, elapsed_ms);
            } else if command == "references" || begins_with(command, "references ") {
                tail := server_command_tail(command, "references");
                request, request_ok := server_parse_request_location(tail, options.request, cwd);
                response := "";
                if !request_ok response = "error,references,missing_location";
                else response = server_source_query_response(files, request, .FIND_USAGES, options.new_name, options);
                table_add(*response_cache, command, response);
                elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
                log("%,ms=%", response, elapsed_ms);
            } else if command == "rename_preview" || begins_with(command, "rename_preview ") {
                tail := server_command_tail(command, "rename_preview");
                location_text, rename_name := split_first_word(tail);
                if rename_name.count == 0 && location_text.count > 0 && find_last(location_text, #char "@") < 0 {
                    rename_name = location_text;
                    location_text = "";
                }
                if rename_name.count == 0 rename_name = options.new_name;

                request, request_ok := server_parse_request_location(location_text, options.request, cwd);
                response := "";
                if !request_ok response = "error,rename_preview,missing_location";
                else response = server_source_query_response(files, request, .RENAME, rename_name, options);
                table_add(*response_cache, command, response);
                elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
                log("%,ms=%", response, elapsed_ms);
            } else {
                elapsed_ms := to_float64_seconds(current_time_monotonic() - start) * 1000.0;
                log("error,unknown_command,%,ms=%", command, elapsed_ms);
            }
        }

        server_flush_stdout();
    }

    return true;
}

try_run_indexed_command :: (options: Program_Options) -> (handled: bool, ok: bool) {
    if options.force_full_project return false, false;
    if options.mode == .RENAME && options.apply return false, false;

    if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_header();
    reset_tool_profile_counts();

    profile_start: Apollo_Time;
    profile_start = profile_timer_start();
    files, files_ok := load_source_files(options);
    if !files_ok return true, false;
    if PROGRAMMING_PROFILE_ENABLED && options.profile {
        print_tool_profile_row("load_project_sources", profile_seconds_since(profile_start));
        print_tool_profile_row("collect_paths", tool_profile_collect_seconds);
        print_tool_profile_row("read_files", tool_profile_read_seconds);
    }

    request_file := find_project_file(files, options.request.filename);
    if request_file == null return false, false;

    profile_start = profile_timer_start();
    request_name := identifier_at_location(request_file.source, options.request.line, options.request.column);
    if request_name.count == 0 return false, false;

    declaration, declaration_ok := find_unique_source_declaration(files, request_name);
    if !declaration_ok return false, false;
    if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("resolve_name_index", profile_seconds_since(profile_start));

    profile_start = profile_timer_start();

    if options.mode == .FIND_DEF {
        log("%@%:%", declaration.file_path, declaration.node.span.line, declaration.node.span.column);
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("run_command", profile_seconds_since(profile_start));
        return true, true;
    }

    total_edits, project_edits, module_edits, files_with_edits := count_identifier_occurrences_by_area(files, request_name, options);

    if options.mode == .FIND_USAGES {
        log("Usages of '%'", request_name);
        log(" ");
        log("  Declared at: %@%:%", declaration.file_path, declaration.node.span.line, declaration.node.span.column);
        log("  Total usages: %", total_edits);
        log("  Files: %", files_with_edits);
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("run_command", profile_seconds_since(profile_start));
        return true, true;
    }

    if options.mode == .RENAME {
        if !is_valid_identifier(options.new_name) {
            log_error("New name '%' is not a valid simple Jai identifier.", options.new_name);
            return true, false;
        }

        warnings := 0;

        log("Rename Preview");
        log(" ");
        log("  Symbol:      '%'", request_name);
        log("  New name:    '%'", options.new_name);
        log("  Declared at: %@%:%", declaration.file_path, declaration.node.span.line, declaration.node.span.column);
        log("  Total edits: %", total_edits);
        if module_edits > 0 {
            log("  Project edits: %", project_edits);
            log("  Jai module edits: %", module_edits);
            log(" ");
            log("Applying this rename requires -allow_jai_modules_rename because it would modify the Jai modules directory.");
        }
        if warnings > 0 log("  Warnings:    %", warnings);
        else log("This is a preview. Add -y to apply the rename.");

        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("run_command", profile_seconds_since(profile_start));
        return true, true;
    }

    return false, false;
}

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
        } else if arg == "-allow_jai_modules_rename" {
            options.allow_jai_modules_rename = true;
        } else if arg == "-full_project" {
            options.force_full_project = true;
        } else if arg == "-profile" {
            if !PROGRAMMING_PROFILE_ENABLED {
                log_error("-profile requires PROGRAMMING_PROFILE_ENABLED :: true.");
                return options, false;
            }
            options.profile = true;
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

    indexed_handled, indexed_ok := try_run_indexed_command(options);
    if indexed_handled return indexed_ok;

    if options.mode == .FIND_DEF && !options.force_full_project {
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_header();
        reset_tool_profile_counts();
        profile_start: Apollo_Time;
        profile_start = profile_timer_start();
        files, inputs, project_ok := load_project_for_find_def(options);
        if !project_ok return false;
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("load_project_summary", profile_seconds_since(profile_start));
        if PROGRAMMING_PROFILE_ENABLED && options.profile {
            print_tool_profile_count("summary_files", tool_profile_summary_file_count);
            print_tool_profile_count("full_parse_files", tool_profile_full_parse_file_count);
            print_tool_profile_count("summary_declarations", tool_profile_summary_declaration_count);
            print_tool_profile_row("collect_paths", tool_profile_collect_seconds);
            print_tool_profile_row("read_files", tool_profile_read_seconds);
            print_tool_profile_row("parse_target_file", tool_profile_target_parse_seconds);
            print_tool_profile_row("summarize_files", tool_profile_summary_parse_seconds);
        }

        profile_start = profile_timer_start();
        resolver := resolve_project_symbols_for_file(inputs, options.request.filename);
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("resolve_target_file", profile_seconds_since(profile_start));

        profile_start = profile_timer_start();
        ok := run_find_def(files, resolver, options);
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("run_command", profile_seconds_since(profile_start));
        return ok;
    }

    if (options.mode == .FIND_USAGES || options.mode == .RENAME) && !options.force_full_project {
        if options.mode == .RENAME && !is_valid_identifier(options.new_name) {
            log_error("New name '%' is not a valid simple Jai identifier.", options.new_name);
            return false;
        }

        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_header();
        reset_tool_profile_counts();
        profile_start: Apollo_Time;
        profile_start = profile_timer_start();
        seed_files, seed_inputs, seed_ok := load_project_for_find_def(options);
        if !seed_ok return false;
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("load_project_summary", profile_seconds_since(profile_start));
        if PROGRAMMING_PROFILE_ENABLED && options.profile {
            print_tool_profile_count("summary_files", tool_profile_summary_file_count);
            print_tool_profile_count("full_parse_files", tool_profile_full_parse_file_count);
            print_tool_profile_count("summary_declarations", tool_profile_summary_declaration_count);
            print_tool_profile_row("collect_paths", tool_profile_collect_seconds);
            print_tool_profile_row("read_files", tool_profile_read_seconds);
            print_tool_profile_row("parse_target_file", tool_profile_target_parse_seconds);
            print_tool_profile_row("summarize_files", tool_profile_summary_parse_seconds);
        }

        profile_start = profile_timer_start();
        seed_resolver := resolve_project_symbols_for_file(seed_inputs, options.request.filename);
        seed_symbol := find_symbol_for_request(seed_resolver, options.request);
        if seed_symbol == null {
            log_error("No symbol found at %@%:%", options.request.filename, options.request.line, options.request.column);
            return false;
        }
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("resolve_seed_symbol", profile_seconds_since(profile_start));

        secondary_name := "";
        if options.mode == .RENAME secondary_name = options.new_name;

        profile_start = profile_timer_start();
        candidate_paths, scanned_files, promoted_files, promote_ok := promote_identifier_candidates(*seed_files, *seed_inputs, options, seed_symbol.name, secondary_name);
        if !promote_ok return false;
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("promote_candidates", profile_seconds_since(profile_start));
        if PROGRAMMING_PROFILE_ENABLED && options.profile {
            print_tool_profile_count("candidate_scanned_files", scanned_files);
            print_tool_profile_count("candidate_promoted_files", promoted_files);
        }

        profile_start = profile_timer_start();
        resolver := resolve_project_symbols_for_files(seed_inputs, candidate_paths);
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("resolve_candidate_files", profile_seconds_since(profile_start));

        profile_start = profile_timer_start();
        ok := false;
        if options.mode == {
            case .FIND_USAGES; ok = run_find_usages(seed_files, resolver, options);
            case .RENAME; ok = run_rename(seed_files, resolver, options);
            case;
        }
        if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("run_command", profile_seconds_since(profile_start));
        return ok;
    }

    if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_header();
    profile_start: Apollo_Time;
    profile_start = profile_timer_start();
    files, inputs, project_ok := load_project(options);
    if !project_ok return false;
    if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("load_project_full", profile_seconds_since(profile_start));

    profile_start = profile_timer_start();
    resolver := resolve_project_symbols(inputs);
    if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("resolve_project_full", profile_seconds_since(profile_start));

    profile_start = profile_timer_start();
    ok := false;
    if options.mode == {
        case .FIND_DEF; ok = run_find_def(files, resolver, options);
        case .FIND_USAGES; ok = run_find_usages(files, resolver, options);
        case .RENAME; ok = run_rename(files, resolver, options);
        case .NONE;
    }
    if PROGRAMMING_PROFILE_ENABLED && options.profile print_tool_profile_row("run_command", profile_seconds_since(profile_start));

    return ok;
}
