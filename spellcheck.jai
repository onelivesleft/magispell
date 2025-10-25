// TODO
// [x] Switch to windows spellchecker
// [x] Select dictionary
// [x] Menu upgrades
//  [x] Move preferred languages to main menu, above the fold
//  [x] Section breaks
//  [x] Checkmarks
// [ ] Cycle suggestions on subsequent presses
// [ ] User hotkeys for word selection
//  [ ] Per-process specific?
// [ ] User select word keystring
//  [ ] Initially: left/right/both ctrl + double/triple press?
//  [ ] Subsequently: choose hotkey
// [ ] Popup suggestions menu
// [ ] Store config
// [ ] Maybe allow user to check currently selected text?
// [ ] SFX

APPLICATION_NAME :: "Magispell";
VERSION :: "v0.01";
APPLICATION_NAME_AND_VERSION :: #run sprint("% %", APPLICATION_NAME, VERSION);
RELEASE_MODE : enum {RELEASE; DEBUG;} : .DEBUG;

#if RELEASE_MODE == .RELEASE then #run disable_runtime_console();


#import "GUI";

#import "Basic";
#import "Clipboard";
#import "File";
#import "Math";
#import "Strings";
#import "Windows";
#import "Windows_Utf8";

Spell_Checker :: #import "Windows_Spell_Checker";


hook: HHOOK;

Keyboard_Event :: struct {
    event_id: WPARAM;
    using kb_struct: KBDLLHOOKSTRUCT;
}

key_events: [128] Keyboard_Event;
key_events_head := 0;
key_events_tail := 0;

last_control_press: float64;
last_control_release: float64;
control_press_consecutive_count := 0;
control_is_down := false;

double_press_interval :: 0.2;
small_press_interval :: 1.0 / 1000;
large_press_interval :: 3.0 / 1000;

old_clipboard_value := "";
clipboard_sentinel :: "!#@";
fetched_clipboard_at: float64;
clipboard_fetch_timeout :: 2.0;

Key_Chord :: struct {
    virtual_code: u16;
    ctrl: bool;
    shift: bool;
    alt: bool;
}


get_emit_key :: (virtual_code: u16, direction: type_of(Key_To_Emit.direction)) -> Key_To_Emit {
    result: Key_To_Emit;
    result.type = .KEY;
    result.virtual_code = virtual_code;
    result.direction = direction;
    return result;
}

get_emit_delay :: (delay: float64) -> Key_To_Emit {
    result: Key_To_Emit;
    result.type = .DELAY;
    result.delay = delay;
    return result;
}


Key_Tracker :: struct {
    virtual_code: u16;
    is_down: bool;
    last_pressed_frame_index: int;
    last_released_frame_index: int;
    last_pressed_at: float64;
    last_released_at: float64;
    consecutive_pressed_interval: float64;
    consecutive_press_count: int;
}

init_key_tracker :: (key_tracker: *Key_Tracker, virtual_code: u16) {
    key_tracker.virtual_code = virtual_code;
    state := GetAsyncKeyState(virtual_code);
    key_tracker.is_down = state & 0x8000 != 0;
    array_add(*key_trackers, key_tracker);
}

update_key_tracker :: (using key_tracker: *Key_Tracker, key_event: Keyboard_Event) {
    if key_event.vkCode != virtual_code {
        if key_event.event_id == WM_KEYDOWN
            consecutive_press_count = 0;
    }
    else if key_event.event_id == WM_KEYDOWN {
        consecutive_pressed_interval = frame.time - last_pressed_at;
        last_pressed_frame_index = frame.index;
        last_pressed_at = frame.time;
        consecutive_press_count += 1;
        is_down = true;
    }
    else if key_event.event_id == WM_KEYUP {
        last_released_frame_index = frame.index;
        last_released_at = frame.time;
        is_down = false;
    }
}

key_trackers: [..] *Key_Tracker;
active_key_tracker: *Key_Tracker;

left_control: Key_Tracker;
right_control: Key_Tracker;

Key_To_Emit :: struct {
    type : enum { KEY; DELAY; }

    virtual_code: u16;
    direction: enum { UP; DOWN; }

    #place virtual_code;
    delay: float64;
}

Key_Flags :: enum_flags u8 {
    CTRL :: 1;
    SHIFT :: 2;
    ALT :: 4;
}

key_emit_queue: [128] Key_To_Emit;
key_emit_head: int;
key_emit_tail: int;

spell_check_results: [] Spell_Checker.Spell_Check_Results;
word_to_check: string;
last_suggested_word: string;
user_preferred_languages: [..] Menu_Item;
other_supported_languages: [..] Menu_Item;

state: enum {
    DORMANT;
    WAITING_FOR_KEY_RELEASE;
    TRIGGERED;
    SENDING_FETCH_WORD_KEYCODES;
    WAITING_FOR_WORD;
    SENDING_REPLACE_WORD_KEYCODES;
    SENDING_NO_REPLACE_KEYCODES;
}

should_quit := false;

main :: () {
    Spell_Checker.init();
    defer Spell_Checker.deinit();
    refresh_language_menus();

    init_key_tracker(*left_control, VK_LCONTROL);
    init_key_tracker(*right_control, VK_RCONTROL);

    window_width :: 512;
    window_height :: 512;
    application_panel := gui_create_application_window(APPLICATION_NAME_AND_VERSION, window_width, window_height, flags=.DEFAULT|.START_MINIMIZED|.HAS_NOTIFICATION_ICON|.HIDE_FROM_TASKBAR);

    hook = SetWindowsHookExA(WH_KEYBOARD_LL, keyboard_hook, null, 0);
    if !hook  exit(1);

    base_color :: Vector4.{.15, .08, .08, 1};
    color: Vector4;


    while !should_quit {
        should_quit = gui_begin_frame();
        frame.no_sleep = true;

        if key_events_tail != key_events_head {
            while key_events_tail != key_events_head {
                key_events_tail += 1;
                index := key_events_tail % key_events.count;
                key_event := key_events[index];
                for key_trackers  update_key_tracker(it, key_event);
            }
        }

        if gui_notification_icon_was_clicked() {
            gui_system_menu(
                .[ menu_item(APPLICATION_NAME, is_default=true) ],
                user_preferred_languages,
                .[ menu_item("Exit", quit, icon=.SUB_MENU_CLOSE) ]
            );
        }

        if state == .DORMANT {
            if left_control.last_pressed_frame_index == frame.index {
                if left_control.consecutive_press_count == 2 && left_control.consecutive_pressed_interval <= double_press_interval
                    state = .WAITING_FOR_KEY_RELEASE;
                    active_key_tracker = *left_control;
            }

            if right_control.last_pressed_frame_index == frame.index {
                if right_control.consecutive_press_count == 2 && right_control.consecutive_pressed_interval <= double_press_interval
                    state = .WAITING_FOR_KEY_RELEASE;
                    active_key_tracker = *right_control;
            }
        }

        if state == .WAITING_FOR_KEY_RELEASE {
            if active_key_tracker.last_released_frame_index == frame.index
                state = .TRIGGERED;
        }

        if state == .TRIGGERED {
            if old_clipboard_value  free(old_clipboard_value);
            old_clipboard_value = os_clipboard_get_text();
            os_clipboard_set_text(clipboard_sentinel);

            add_key(.CTRL, #char "W");
            add_key(.CTRL, #char "C");
            state = .SENDING_FETCH_WORD_KEYCODES;
        }

        if state == .SENDING_FETCH_WORD_KEYCODES {
            still_sending := send_next_key();
            if !still_sending {
                fetched_clipboard_at = frame.time;
                state = .WAITING_FOR_WORD;
            }
        }

        if state == .WAITING_FOR_WORD {
            if frame.time - fetched_clipboard_at > clipboard_fetch_timeout {
                show_error("Timed out waiting for clipboard to change.");
                state = .DORMANT;
            }
            else {
                clipboard_text := os_clipboard_get_text();
                if clipboard_text != clipboard_sentinel {
                    fetched_clipboard_at = 0;

                    found_last_suggested_word := false;

                    if spell_check_results && spell_check_results[0].replacement_suggestions && last_suggested_word && clipboard_text == last_suggested_word {
                        if last_suggested_word == word_to_check {
                            free(last_suggested_word);
                            last_suggested_word = copy_string(spell_check_results[0].replacement_suggestions[0]);
                            found_last_suggested_word = true;
                        }
                        else {
                            set_last_suggested_word := false;
                            for result: spell_check_results {
                                for suggestion: result.replacement_suggestions {
                                    if found_last_suggested_word {
                                        free(last_suggested_word);
                                        last_suggested_word = copy_string(suggestion);
                                        set_last_suggested_word = true;
                                        break result;
                                    }
                                    else if suggestion == last_suggested_word {
                                        found_last_suggested_word = true;
                                    }
                                }
                            }
                            if found_last_suggested_word && !set_last_suggested_word {
                                free(last_suggested_word);
                                last_suggested_word = copy_string(word_to_check);
                            }
                        }
                    }

                    if !found_last_suggested_word {
                        if word_to_check  free(word_to_check);
                        word_to_check = copy_string(clipboard_text);

                        print("Asked to check word: %\n", word_to_check);

                        if last_suggested_word  free(last_suggested_word);
                        Spell_Checker.free_spell_check_results(spell_check_results);
                        spell_check_results=, error := Spell_Checker.check_spelling(word_to_check);

                        if error || !spell_check_results || !spell_check_results[0].replacement_suggestions {
                            if error  print("Error: %\n", error);
                            last_suggested_word = "";
                        }
                        else {
                            last_suggested_word = copy_string(spell_check_results[0].replacement_suggestions[0]);
                        }
                    }

                    if last_suggested_word {
                        print("Trying to correct to: %\n", last_suggested_word);
                        os_clipboard_set_text(last_suggested_word);
                        add_key(.CTRL, #char "V");
                        state = .SENDING_REPLACE_WORD_KEYCODES;
                    }
                    else {
                        print("Aborting\n");
                        state = .DORMANT;
                    }
                }
                if clipboard_text  free(clipboard_text);
            }
        }

        if state == .SENDING_REPLACE_WORD_KEYCODES
        || state == .SENDING_NO_REPLACE_KEYCODES {
            still_sending := send_next_key();
            if !still_sending  state = .DORMANT;
        }

        reset_temporary_storage();
    }

    gui_shutdown();
}

quit :: () {
    should_quit = true;
}

select_language :: (index: int) {
    error := Spell_Checker.init(Spell_Checker.supported_languages[index]);
    if error  print("Error: %\n", error);
    refresh_language_menus();
}

refresh_language_menus :: () {
    array_reset(*user_preferred_languages);
    array_reset(*other_supported_languages);
    for Spell_Checker.supported_languages {
        is_checked := it == Spell_Checker.current_language;
        menu := ifx it_index < Spell_Checker.user_preferred_language_count || is_checked
                then *user_preferred_languages
                else *other_supported_languages;
        array_add(menu, menu_item(it, select_language, it_index, is_checked=is_checked));
    }
    array_add(*user_preferred_languages, sub_menu("More...", other_supported_languages));
}

show_error :: (msg: string) {
}

add_small_delay :: () {
    delay := get_emit_delay(small_press_interval);
    add_to_queue(delay);
}

add_large_delay :: () {
    delay := get_emit_delay(large_press_interval);
    add_to_queue(delay);
}

add_key :: inline (keycode: u16) {
    add_key(0, keycode);
}

add_key :: (flags: Key_Flags, keycode: u16) {
    has_modifier := flags != 0;

    if flags & .CTRL   add_to_queue(get_emit_key(VK_LCONTROL, .DOWN));
    if flags & .SHIFT  add_to_queue(get_emit_key(VK_LSHIFT, .DOWN));
    if flags & .ALT    add_to_queue(get_emit_key(VK_LALT, .DOWN));

    if has_modifier  add_small_delay();

    add_to_queue(get_emit_key(keycode, .DOWN));
    add_small_delay();
    add_to_queue(get_emit_key(keycode, .UP));

    if has_modifier  add_small_delay();

    if flags & .ALT    add_to_queue(get_emit_key(VK_LALT, .UP));
    if flags & .SHIFT  add_to_queue(get_emit_key(VK_LSHIFT, .UP));
    if flags & .CTRL   add_to_queue(get_emit_key(VK_LCONTROL, .UP));

    add_large_delay();
}

add_to_queue :: (to_emit: Key_To_Emit) {
    key_emit_head = (key_emit_head + 1) % key_emit_queue.count;
    key_emit_queue[key_emit_head] = to_emit;
}

do_not_send_keys_until_after: float64;

send_next_key :: () -> still_sending: bool {
    if frame.time < do_not_send_keys_until_after  return true;

    to_emit := key_emit_queue[key_emit_tail];
    key_emit_tail = (key_emit_tail + 1) % key_emit_queue.count;

    if #complete to_emit.type == {
        case .DELAY;
            do_not_send_keys_until_after = frame.time + to_emit.delay;
            return true;

        case .KEY;
            generate_keystroke(to_emit.virtual_code, to_emit.direction);
            return key_emit_head != key_emit_tail;
    }
}

keyboard_hook :: (code: s32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call {
    if code >= 0 {
        ptr := *key_events_head;
        #asm { lock_inc.q [ptr]; }
        index := key_events_head % key_events.count;
        key_event := *key_events[index];
        key_event.event_id = wParam;
        key_event.kb_struct = << (cast(*KBDLLHOOKSTRUCT) lParam);
    }
    return CallNextHookEx(hook, code, wParam, lParam);
}

inputs: [..] INPUT;

translate_to_keystroke_string :: (s: string) -> string {
    builder: String_Builder;
    caps_mode := false;
    for 0 .. s.count - 1 {
        char := s[it];
        letter_is_caps := #char "A" <= char && char <= #char "Z";
        if caps_mode != letter_is_caps {
            append(*builder, "s");
            caps_mode = !caps_mode;
        }
        output_char := char;
        if #char "a" <= char && char <= #char "z"  output_char = char + #char "A" - #char "a";
        append(*builder, output_char);
    }
    if caps_mode  append(*builder, "s");
    return builder_to_string(*builder,, temp);
}

generate_keystroke :: (virtual_code: u16, direction: type_of(Key_To_Emit.direction)) {
    array_reset(*inputs);
    input := array_add(*inputs);
    <<input = .{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = virtual_code;
    if direction == .UP  input.ki.dwFlags = KEYEVENTF_KEYUP;

    SendInput(xx inputs.count, inputs.data, size_of(INPUT));
}

generate_keystrokes :: (s: string) {
    array_reset(*inputs);
    ctrl_held := false;
    shift_held := false;
    for 0 .. s.count - 1 {
        char := s[it];

        if char == #char "c" {
            input := array_add(*inputs);
            <<input = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = VK_LCONTROL;
            if ctrl_held  input.ki.dwFlags = KEYEVENTF_KEYUP;
            ctrl_held = !ctrl_held;
        }
        else if char == #char "s" {
            input := array_add(*inputs);
            <<input = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = VK_LSHIFT;
            if shift_held  input.ki.dwFlags = KEYEVENTF_KEYUP;
            shift_held = !shift_held;
        }
        else {
            // Down
            input := array_add(*inputs);
            <<input = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = xx char;

            // Up
            input = array_add(*inputs);
            <<input = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = xx char;
            input.ki.dwFlags = KEYEVENTF_KEYUP;
        }
    }
    assert(!ctrl_held && !shift_held);

    if inputs.count {
        foo := SendInput(xx inputs.count, inputs.data, size_of(INPUT));
        //print("foo = %  err = %\n", foo, GetLastError());
    }
}


HOOKPROC :: #type (code: s32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call;

KBDLLHOOKSTRUCT :: struct {
  vkCode: DWORD;
  scanCode: DWORD;
  flags: DWORD;
  time: DWORD;
  dwExtraInfo: *u64;
}

INPUT_KEYBOARD :: 1;
KEYEVENTF_KEYUP :: 0x2;

INPUT :: struct {
  type: DWORD #align 4;
  union {
    mi: MOUSEINPUT #align 4;
    ki: KEYBDINPUT #align 4;
    hi: HARDWAREINPUT #align 4;
  }
}

LONG :: u64;
WCHAR :: u16;
VK_LALT :: VK_LMENU;

MOUSEINPUT :: struct {
  dx: LONG #align 4;
  dy: LONG #align 4;
  mouseData: DWORD #align 4;
  dwFlags: DWORD #align 4;
  time: DWORD #align 4;
  dwExtraInfo: *u64 #align 4;
}

KEYBDINPUT :: struct {
  wScan: WORD #align 4;
  wVk: WORD #align 4;
  dwFlags: DWORD #align 4;
  time: DWORD #align 4;
  dwExtraInfo: *u64 #align 4;
}

HARDWAREINPUT :: struct {
  uMsg: DWORD;
  wParamL: WORD;
  wParamH: WORD;
}

HHOOK :: *void;
FreeConsole :: () -> bool #foreign kernel32;
GetKeyboardState :: (lpKeyState: *[256] u8) -> bool #foreign user32;
SetWindowsHookExA :: (idHook: s32,  lpfn: HOOKPROC, hmod: HINSTANCE, dwThreadId: s32) -> HHOOK #foreign user32;
CallNextHookEx :: (hhk: HHOOK, nCode: s32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #foreign user32;
SendInput :: (cInputs: u32, pInputs: *INPUT, cbSize: s32) -> u32 #foreign user32;

user32 :: #system_library "user32";
kernel32 :: #system_library "kernel32";

WH_KEYBOARD :: 2;
WH_KEYBOARD_LL :: 13;


