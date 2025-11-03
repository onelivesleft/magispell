// `jai build.jai` to create debug build called spellcheck.exe
// `jai build.jai - release` to create release build called Magispell.exe
// `jai build.jai - no_output` to compile without generating any output (for fast compilation checks while coding)

#import "Basic";
#import "Compiler";
#import "Code_Visit";
#import "Windows_Resources";

src_name :: "spellcheck.jai";
debug_exe_name :: "spellcheck";
release_exe_name :: "Magispell";
path_to_exe := "./";
icon :: "media/icon.ico";

#run {
    exe_name := debug_exe_name;
    optimized := false;
    no_output := false;

    build_options := get_build_options();
    set_build_options_dc(.{do_output=false});
    build_options.output_type = .EXECUTABLE;

    for arg: build_options.compile_time_command_line {
        if arg == {
            case "release";
            optimized = true;
            exe_name = release_exe_name;
            set_optimization(*build_options, .VERY_OPTIMIZED);
            build_options.llvm_options.enable_split_modules = false;
            build_options.array_bounds_check = .ON;
            build_options.null_pointer_check = .ON;
            build_options.arithmetic_overflow_check = .OFF;
            build_options.emit_debug_info = .NONE;
            path_to_exe = "./release/";

            case "no_output";
            no_output = true;
        }
    }
    build_options.output_executable_name = exe_name;
    build_options.output_path = path_to_exe;

    workspace := compiler_create_workspace();
    set_build_options(build_options, workspace);
    if no_output
        set_build_options_dc(.{do_output=false}, workspace);
    else if optimized
        set_build_options_dc(.{append_linker_arguments=.["/SUBSYSTEM:windows", "/ENTRY:mainCRTStartup"]}, workspace);

    compiler_begin_intercept(workspace);

    add_build_string(sprint("BUILD_MODE : enum { DEBUG; RELEASE; NO_OUTPUT; } : %;\n", ifx optimized then ".RELEASE" else ifx no_output then ".NO_OUTPUT" else ".DEBUG"), workspace);
    add_build_file(src_name, workspace);

    while true {
        message := compiler_wait_for_message();
        if !message || message.workspace != workspace continue;
        if message.kind == .COMPLETE break;

        if no_output && message.kind == .PHASE {
            phase := cast(*Message_Phase) message;
            if phase.phase == .TYPECHECKED_ALL_WE_CAN && phase.num_items_waiting_to_typecheck == 0
                exit(0);
        }

        if message.kind == .TYPECHECKED {
            typechecked := cast(*Message_Typechecked) message;
            for body: typechecked.procedure_bodies
                check_for_string_assignments(body);
        }
    }

    compiler_end_intercept(workspace);

    set_icon_by_filename(sprint("%1%2.exe", path_to_exe, exe_name), icon);
}


nodes: [..] *Code_Node;
string_type: *Code_Declaration;

check_for_string_assignments :: (typechecked: Typechecked(Code_Procedure_Body)) {
    body := typechecked.expression;

    array_reset(*nodes);
    get_recursive_nodes_breadth_first(body, *nodes);
    for nodes {
        if it.enclosing_load && it.enclosing_load.enclosing_import.module_name
            continue;

        if it.kind == .BINARY_OPERATOR {
            binary_operator := cast(*Code_Binary_Operator) it;
            if binary_operator.operator_type == #char "=" && binary_operator.left.kind == .IDENT {
                assigned_to_ident := cast(*Code_Ident) binary_operator.left;
                if !assigned_to_ident
                || !assigned_to_ident.resolved_declaration
                || !assigned_to_ident.resolved_declaration.type_inst
                || !assigned_to_ident.resolved_declaration.type_inst.type_valued_expression
                || assigned_to_ident.resolved_declaration.type_inst.type_valued_expression.kind != .IDENT
                    continue;

                ident := cast(*Code_Ident) assigned_to_ident.resolved_declaration.type_inst.type_valued_expression;
                if !string_type && ident.name == "string"
                    string_type = ident.resolved_declaration;

                if ident.resolved_declaration == string_type {
                    compiler_report("Assigning directly to a string.  Use set_string_with_copy or set_string_directly instead.", make_location(binary_operator), .WARNING);
                }
            }
        }
    }
}
