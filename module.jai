/*

A single module that supports compiler-time tools to make programming easier:
  -find_def <file>@<line>:<col>
  -find_usages <file>@<line>:<col>
  -rename <file>@<line>:<col> <new_name> [-y]

Integration into a build script:

  #import "programming";

  #run {
      set_build_options_dc(.{do_output = false});

      tool := programming_parse_args();
      is_tool := tool != .NONE;

      w := compiler_create_workspace("Target workspace");
      options := get_build_options(w);
      copy_commonly_propagated_fields(get_build_options(), *options);
      if is_tool  options.output_type = .NO_OUTPUT;
      set_build_options(options, w);

      compiler_begin_intercept(w);
      add_build_file("src/main.jai", w);
      while true {
          message := compiler_wait_for_message();
          if message.kind == .ERROR  exit(1);
          programming_handle_message(message);
          if message.kind == .COMPLETE  break;
      }
      compiler_end_intercept(w);

      programming_finish();
  };

*/

#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";
#import "Sort";
#import "Basic";

#scope_module

Tool_Mode :: enum {
    NONE;
    FIND_DEF;
    FIND_USAGES;
    RENAME;
}

Location_Request :: struct {
    filename:  string;
    line:      s32;
    character: s32;
}

Buffered_Reference :: struct {
    resolved_declaration: *Code_Declaration;
    filename:   string;
    line:       s32;
    char_start: s32;
    char_end:   s32;
    name:       string;
}

Buffered_Block :: struct {
    block: *Code_Block;
}

Rename_Edit :: struct {
    filename:   string;
    line:       s32;
    char_start: s32;
    char_end:   s32;
    new_text:   string;
}

//  Module state

active_tool:        Tool_Mode;
tool_request:       Location_Request;
rename_new_name:    string;
rename_auto_confirm: bool;

all_references: [..] Buffered_Reference;
all_blocks:     [..] Buffered_Block;

//  Shared utilities

get_node_filename :: (node: *Code_Node) -> string {
    if node == null          return "";
    if !node.enclosing_load  return "";
    return node.enclosing_load.fully_pathed_filename;
}

resolve_path :: (path: string, cwd: string) -> string {
    if path.count == 0                               return path;
    if path.count >= 2 && path[1] == #char ":"       return path;
    if path[0] == #char "/"                          return path;

    result := tprint("%/%", cwd, path);
    for i: 0..result.count-1 {
        if result[i] == #char "\\"  result[i] = #char "/";
    }
    return result;
}

find_last :: (s: string, c: u8) -> s64 {
    i := s.count - 1;
    while i >= 0 {
        if s[i] == c  return i;
        i -= 1;
    }
    return -1;
}

find_first :: (s: string, c: u8) -> s64 {
    for i: 0..s.count-1 {
        if s[i] == c  return i;
    }
    return -1;
}

parse_location :: (arg: string, cwd: string) -> (ok: bool, filename: string, line: s32, col: s32) {
    at_index := find_last(arg, #char "@");
    if at_index < 1  return false, "", 0, 0;

    filename_part := slice(arg, 0, at_index);
    rest := slice(arg, at_index + 1, arg.count - at_index - 1);

    colon_index := find_first(rest, #char ":");
    if colon_index < 1  return false, "", 0, 0;

    line_str := slice(rest, 0, colon_index);
    col_str  := slice(rest, colon_index + 1, rest.count - colon_index - 1);

    ok: bool;
    line_val: s64;
    col_val:  s64;

    line_val, ok = string_to_int(line_str);
    if !ok  return false, "", 0, 0;

    col_val, ok = string_to_int(col_str);
    if !ok  return false, "", 0, 0;

    return true, resolve_path(filename_part, cwd), cast(s32) line_val, cast(s32) col_val;
}

filename_match :: (a: string, b: string) -> bool {
    if a.count == 0 || b.count == 0  return false;
    return a == b || ends_with(a, b) || ends_with(b, a);
}

//  Node buffering 

buffer_node :: (refs: *[..] Buffered_Reference, node: *Code_Node) {
    if node == null  return;

    if node.kind == {
        case .IDENT;
            ident := cast(*Code_Ident) node;
            if ident.resolved_declaration == null  return;
            if ident.name.count == 0               return;

            ref: Buffered_Reference;
            ref.resolved_declaration = ident.resolved_declaration;
            ref.filename   = get_node_filename(node);
            ref.line       = node.l0;
            ref.char_start = node.c0;
            ref.char_end   = node.c0 + cast(s32) ident.name.count;
            ref.name       = ident.name;
            array_add(refs, ref);

        case .DECLARATION;
            decl := cast(*Code_Declaration) node;
            if decl.name.count == 0  return;

            ref: Buffered_Reference;
            ref.resolved_declaration = decl;
            ref.filename   = get_node_filename(node);
            ref.line       = node.l0;
            ref.char_start = node.c0;
            ref.char_end   = node.c0 + cast(s32) decl.name.count;
            ref.name       = decl.name;
            array_add(refs, ref);

            if decl.type_inst    buffer_node(refs, decl.type_inst);
            if decl.expression   buffer_node(refs, decl.expression);

        case .TYPE_INSTANTIATION;
            ti := cast(*Code_Type_Instantiation) node;
            if ti.type_valued_expression  buffer_node(refs, ti.type_valued_expression);
            if ti.pointer_to              buffer_node(refs, ti.pointer_to);
            if ti.array_element_type      buffer_node(refs, ti.array_element_type);
            if ti.type_directive_target    buffer_node(refs, ti.type_directive_target);

        case .BINARY_OPERATOR;
            bin := cast(*Code_Binary_Operator) node;
            if bin.left   buffer_node(refs, bin.left);
            if bin.right  buffer_node(refs, bin.right);

        case .UNARY_OPERATOR;
            un := cast(*Code_Unary_Operator) node;
            if un.subexpression  buffer_node(refs, un.subexpression);

        case .PROCEDURE_CALL;
            call := cast(*Code_Procedure_Call) node;
            if call.procedure_expression  buffer_node(refs, call.procedure_expression);
            for call.arguments_sorted     buffer_node(refs, it);

        case .IF;
            ifc := cast(*Code_If) node;
            if ifc.condition  buffer_node(refs, ifc.condition);

        case .WHILE;
            wh := cast(*Code_While) node;
            if wh.condition  buffer_node(refs, wh.condition);

        case .FOR;
            fc := cast(*Code_For) node;
            if fc.iteration_expression        buffer_node(refs, fc.iteration_expression);
            if fc.iteration_expression_right  buffer_node(refs, fc.iteration_expression_right);
            if fc.ident_decl  buffer_node(refs, cast(*Code_Node) fc.ident_decl);
            if fc.index_decl  buffer_node(refs, cast(*Code_Node) fc.index_decl);

        case .RETURN;
            ret := cast(*Code_Return) node;
            for ret.arguments_sorted  buffer_node(refs, it);

        case .CAST;
            c := cast(*Code_Cast) node;
            if c.target_type  buffer_node(refs, c.target_type);
            if c.expression   buffer_node(refs, c.expression);
    }
}

//  Block buffering (needed for rename collision detection)

buffer_block :: (blks: *[..] Buffered_Block, block: *Code_Block) {
    if block == null  return;
    for blks.*  { if it.block == block  return; }
    array_add(blks, .{block});
}

buffer_block_recursive :: (blks: *[..] Buffered_Block, block: *Code_Block) {
    if block == null  return;
    buffer_block(blks, block);
    for block.statements {
        if it == null  continue;
        if it.kind == {
            case .IF;
                ifc := cast(*Code_If) it;
                if ifc.then_block  buffer_block_recursive(blks, ifc.then_block);
                if ifc.else_block  buffer_block_recursive(blks, ifc.else_block);
            case .WHILE;
                wh := cast(*Code_While) it;
                if wh.block  buffer_block_recursive(blks, wh.block);
            case .FOR;
                fc := cast(*Code_For) it;
                if fc.block  buffer_block_recursive(blks, fc.block);
                if fc.macro_expansion_procedure_call {
                    mc := fc.macro_expansion_procedure_call;
                    if mc.macro_expansion_block  buffer_block_recursive(blks, mc.macro_expansion_block);
                }
            case .BLOCK;
                buffer_block_recursive(blks, cast(*Code_Block) it);
            case .PUSH_CONTEXT;
                pc := cast(*Code_Push_Context) it;
                if pc.block  buffer_block_recursive(blks, pc.block);
            case .DEFER;
                df := cast(*Code_Defer) it;
                if df.block  buffer_block_recursive(blks, df.block);
        }
    }
}

buffer_statements_recursive :: (refs: *[..] Buffered_Reference, block: *Code_Block) {
    if block == null  return;

    for block.members  buffer_node(refs, it);
    for block.statements {
        if it == null  continue;
        buffer_node(refs, it);

        if it.kind == {
            case .IF;
                ifc := cast(*Code_If) it;
                if ifc.then_block  buffer_statements_recursive(refs, ifc.then_block);
                if ifc.else_block  buffer_statements_recursive(refs, ifc.else_block);
            case .WHILE;
                wh := cast(*Code_While) it;
                if wh.block  buffer_statements_recursive(refs, wh.block);
            case .FOR;
                fc := cast(*Code_For) it;
                if fc.block  buffer_statements_recursive(refs, fc.block);
                if fc.macro_expansion_procedure_call {
                    mc := fc.macro_expansion_procedure_call;
                    if mc.macro_expansion_block  buffer_statements_recursive(refs, mc.macro_expansion_block);
                    for mc.arguments_sorted  buffer_node(refs, it);
                }
            case .BLOCK;
                buffer_statements_recursive(refs, cast(*Code_Block) it);
            case .PUSH_CONTEXT;
                pc := cast(*Code_Push_Context) it;
                if pc.block  buffer_statements_recursive(refs, pc.block);
            case .DEFER;
                df := cast(*Code_Defer) it;
                if df.block  buffer_statements_recursive(refs, df.block);
        }
    }
}

//  Shared resolution helpers

resolve_target :: (request: Location_Request, refs: [] Buffered_Reference) -> (decl: *Code_Declaration, name: string) {
    for refs {
        if it.filename.count == 0                        continue;
        if !filename_match(it.filename, request.filename) continue;
        if it.line != request.line                       continue;
        if request.character < it.char_start             continue;
        if request.character >= it.char_end              continue;

        return it.resolved_declaration, it.name;
    }
    return null, "";
}

report_no_symbol :: (request: Location_Request, refs: [] Buffered_Reference) {
    has_any_from_file := false;
    for refs {
        if it.filename.count == 0  continue;
        if filename_match(it.filename, request.filename) {
            has_any_from_file = true;
            break;
        }
    }

    if !has_any_from_file {
        log_error("No references found from file '%'.\nThat file must be part of the target workspace (i.e. included in the code being built via #load, #import, or add_build_file).", request.filename);
    } else {
        log_error("No symbol found at %:%:%", request.filename, request.line, request.character);
    }
}

find_parent_block :: (blks: [] Buffered_Block, decl: *Code_Declaration) -> *Code_Block {
    for bb: blks {
        for bb.block.members {
            if cast(*Code_Node) it == cast(*Code_Node) decl  return bb.block;
        }
    }
    return null;
}

collect_matching_refs :: (target: *Code_Declaration, refs: [] Buffered_Reference) -> ([..] Buffered_Reference, s32) {
    matching: [..] Buffered_Reference;
    total: s32 = 0;

    for ref: refs {
        if ref.resolved_declaration != target  continue;

        already := false;
        for m: matching {
            if m.filename == ref.filename && m.line == ref.line && m.char_start == ref.char_start {
                already = true;
                break;
            }
        }
        if already  continue;

        total += 1;
        array_add(*matching, ref);
    }

    return matching, total;
}

File_Count :: struct {
    filename: string;
    count:    s32;
}

collect_file_counts :: (matching: [] Buffered_Reference) -> [..] File_Count {
    file_counts: [..] File_Count;
    for ref: matching {
        found := false;
        for *fc: file_counts {
            if fc.filename == ref.filename { fc.count += 1; found = true; break; }
        }
        if !found  array_add(*file_counts, File_Count.{ref.filename, 1});
    }
    return file_counts;
}

display_refs_by_file :: (matching: [] Buffered_Reference, file_counts: [] File_Count) {
    for fc: file_counts {
        log("  %  (% occurrences):", fc.filename, fc.count);

        contents, success := read_entire_file(fc.filename);
        lines: [] string;
        if success  lines = split(contents, "\n");

        lines_shown: [..] s32;

        for ref: matching {
            if ref.filename != fc.filename  continue;

            already_shown := false;
            for ls: lines_shown  if ls == ref.line { already_shown = true; break; }
            if already_shown  continue;
            array_add(*lines_shown, ref.line);

            line_idx := ref.line - 1;
            if !success || line_idx < 0 || line_idx >= lines.count {
                log("    %: (could not read line)", ref.line);
                continue;
            }

            log("    %: %", ref.line, lines[line_idx]);
        }

        log(" ");
    }
}

//  Tool-specific finish logic

finish_find_def :: () {
    target, name := resolve_target(tool_request, all_references);
    if target == null {
        report_no_symbol(tool_request, all_references);
        return;
    }

    decl_file := get_node_filename(cast(*Code_Node) target);
    log("%@%:%", decl_file, target.l0, target.c0);
}

finish_find_usages :: () {
    target, old_name := resolve_target(tool_request, all_references);
    if target == null {
        report_no_symbol(tool_request, all_references);
        return;
    }

    matching, total := collect_matching_refs(target, all_references);
    file_counts := collect_file_counts(matching);

    decl_file := get_node_filename(cast(*Code_Node) target);

    log("Usages of '%'", old_name);
    log(" ");
    log("  Declared at: %:%:%", decl_file, target.l0, target.c0);
    log("  Total usages: %", total);
    log(" ");

    display_refs_by_file(matching, file_counts);
}

finish_rename :: () {
    request := tool_request;

    log("Collected % references, % blocks", all_references.count, all_blocks.count);

    target, old_name := resolve_target(request, all_references);
    if target == null {
        report_no_symbol(request, all_references);
        return;
    }

    // collision check
    target_block := find_parent_block(all_blocks, target);
    if target_block != null {
        for all_references {
            if it.resolved_declaration == target   continue;
            if it.name != rename_new_name          continue;
            other_decl := it.resolved_declaration;
            if other_decl == null  continue;
            other_block := find_parent_block(all_blocks, other_decl);
            if other_block == target_block {
                decl_file := get_node_filename(cast(*Code_Node) other_decl);
                log_error("Rename would collide with existing symbol '%' declared at %:%:%",
                    rename_new_name, decl_file, other_decl.l0, other_decl.c0);
                return;
            }
        }
    }

    matching, total := collect_matching_refs(target, all_references);
    file_counts := collect_file_counts(matching);

    decl_file := get_node_filename(cast(*Code_Node) target);

    log("Rename Preview");
    log(" ");
    log("  Symbol:      '%'", old_name);
    log("  New name:    '%'", rename_new_name);
    log("  Declared at: %:%:%", decl_file, target.l0, target.c0);
    log(" ");
    log("  Total occurrences: %", total);
    log(" ");

    display_refs_by_file(matching, file_counts);

    if !rename_auto_confirm {
        log("This is a preview. Add -y to apply the rename.");
        return;
    }

    // build edits
    collected_edits: [..] Rename_Edit;

    for all_references {
        if it.resolved_declaration != target  continue;

        edit: Rename_Edit;
        edit.filename   = it.filename;
        edit.line       = it.line;
        edit.char_start = it.char_start;
        edit.char_end   = it.char_end;
        edit.new_text   = rename_new_name;

        already := false;
        for collected_edits {
            if it.filename == edit.filename && it.line == edit.line && it.char_start == edit.char_start {
                already = true; break;
            }
        }
        if !already  array_add(*collected_edits, edit);
    }

    log(" ");
    log("Applying % edits...", collected_edits.count);

    if collected_edits.count == 0 { log("Nothing to rename."); return; }

    quick_sort(collected_edits, (a: Rename_Edit, b: Rename_Edit) -> s64 {
        if a.line != b.line  return cast(s64)(b.line - a.line);
        return cast(s64)(b.char_start - a.char_start);
    });

    files_done: [..] string;

    for edit: collected_edits {
        already_done := false;
        for files_done  if it == edit.filename { already_done = true; break; }
        if already_done  continue;

        array_add(*files_done, edit.filename);

        contents, success := read_entire_file(edit.filename);
        if !success { log_error("Could not read '%'", edit.filename); continue; }

        lines := split(contents, "\n");
        count := 0;

        for e: collected_edits {
            if e.filename != edit.filename  continue;
            line_idx := e.line - 1;
            if line_idx < 0 || line_idx >= lines.count  continue;

            line := lines[line_idx];
            col_start := e.char_start - 1;
            col_end   := e.char_end - 1;
            if col_start < 0 || col_end > line.count  continue;

            new_line := join(
                slice(line, 0, col_start),
                e.new_text,
                slice(line, col_end, line.count - col_end)
            );
            lines[line_idx] = new_line;
            count += 1;
        }

        new_contents := join(..lines, separator = "\n");
        write_entire_file(edit.filename, new_contents);
        log("  Renamed % occurrences in '%'", count, edit.filename);
    }

    log(" ");
    log("Done.");
}

//  public api

#scope_export

programming_parse_args :: () -> Tool_Mode {
    args := get_build_options().compile_time_command_line;
    cwd  := get_working_directory();

    i := 0;
    while i < args.count {
        if args[i] == "-find_def" {
            i += 1;
            if i < args.count {
                ok, filename, line, col := parse_location(args[i], cwd);
                if ok {
                    tool_request.filename  = filename;
                    tool_request.line      = line;
                    tool_request.character = col;
                    i += 1;
                }
            }

            if tool_request.filename.count > 0
            && tool_request.line > 0
            && tool_request.character > 0 {
                active_tool = .FIND_DEF;
                return .FIND_DEF;
            }

            log_error("Incomplete arguments. Usage: -find_def <file>@<line>:<col>");
            return .NONE;
        }

        if args[i] == "-find_usages" {
            i += 1;
            if i < args.count {
                ok, filename, line, col := parse_location(args[i], cwd);
                if ok {
                    tool_request.filename  = filename;
                    tool_request.line      = line;
                    tool_request.character = col;
                    i += 1;
                }
            }

            if tool_request.filename.count > 0
            && tool_request.line > 0
            && tool_request.character > 0 {
                active_tool = .FIND_USAGES;
                log("Find usages: '%' at %:%:%",
                    tool_request.filename,
                    tool_request.filename,
                    tool_request.line,
                    tool_request.character);
                return .FIND_USAGES;
            }

            log_error("Incomplete arguments. Usage: -find_usages <file>@<line>:<col>");
            return .NONE;
        }

        if args[i] == "-rename" {
            i += 1;
            if i < args.count {
                ok, filename, line, col := parse_location(args[i], cwd);
                if ok {
                    tool_request.filename  = filename;
                    tool_request.line      = line;
                    tool_request.character = col;
                    i += 1;
                }
            }

            if i < args.count && args[i][0] != #char "-" {
                rename_new_name = args[i];
                i += 1;
            }

            // scan remaining args for -y
            while i < args.count {
                if args[i] == "-y"  rename_auto_confirm = true;
                i += 1;
            }

            if tool_request.filename.count > 0
            && tool_request.line > 0
            && tool_request.character > 0
            && rename_new_name.count > 0 {
                active_tool = .RENAME;
                log("Rename: '%' at %:%:% -> '%'",
                    tool_request.filename, tool_request.filename,
                    tool_request.line, tool_request.character,
                    rename_new_name);
                return .RENAME;
            }

            log_error("Incomplete rename arguments. Usage: -rename <file>@<line>:<col> <new_name> [-y]");
            return .NONE;
        }

        i += 1;
    }

    return .NONE;
}

programming_handle_message :: (message: *Message) {
    if active_tool == .NONE  return;

    if message.kind == {
        case .TYPECHECKED;
            tc := cast(*Message_Typechecked) message;

            for tc.all {
                buffer_node(*all_references, it.expression);
                for sub: it.subexpressions {
                    buffer_node(*all_references, sub);
                }

                if it.expression != null && it.expression.kind == .PROCEDURE_BODY {
                    body := cast(*Code_Procedure_Body) it.expression;
                    if body.block {
                        buffer_block_recursive(*all_blocks, body.block);
                        buffer_statements_recursive(*all_references, body.block);
                    }
                }
            }

            for tc.procedure_headers {
                header := it.expression;
                for header.arguments  buffer_node(*all_references, cast(*Code_Node) it);
                for header.returns    buffer_node(*all_references, cast(*Code_Node) it);
            }

            for tc.structs {
                s := it.expression;
                if s.block {
                    buffer_block(*all_blocks, s.block);
                    for s.block.members    buffer_node(*all_references, it);
                    for s.block.statements buffer_node(*all_references, it);
                }
                if s.arguments_block {
                    buffer_block(*all_blocks, s.arguments_block);
                    for s.arguments_block.members  buffer_node(*all_references, it);
                }
                if s.constants_block {
                    buffer_block(*all_blocks, s.constants_block);
                    for s.constants_block.members  buffer_node(*all_references, it);
                }
            }

            for tc.procedure_bodies {
                body := it.expression;
                if body.block {
                    buffer_block_recursive(*all_blocks, body.block);
                    buffer_statements_recursive(*all_references, body.block);
                }
            }
    }
}

programming_finish :: () {
    if active_tool == {
        case .FIND_DEF;     finish_find_def();
        case .FIND_USAGES;  finish_find_usages();
        case .RENAME;       finish_rename();
    }
}
