APPLICATION_NAME :: "Magispell";
VERSION :: "v0.01";
APPLICATION_NAME_AND_VERSION :: #run sprint("% %", APPLICATION_NAME, VERSION);
// BUILD_MODE : enum { DEBUG; RELEASE; }; is inserted by build.jai

// TODO
// [x] Switch to windows spellchecker
// [x] Select dictionary
// [x] Menu upgrades
//  [x] Move preferred languages to main menu, above the fold
//  [x] Section breaks
//  [x] Checkmarks
// [ ] Disallow spaces in answers (we are just correcting single words)
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
// [ ] Toasts (messages, errors)


spell_check_results: [] Spell_Checker.Spell_Check_Results;
word_to_check: string;
last_suggested_word: string;
user_preferred_languages: [..] Menu_Item;
other_supported_languages: [..] Menu_Item;

double_press_window :: 0.2;
small_press_interval :: 1.0 / 1000;
large_press_interval :: 3.0 / 1000;

old_clipboard_value := "";
clipboard_sentinel :: "!#@";
fetched_clipboard_at: float64;
clipboard_fetch_timeout :: 2.0;

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

    window_width :: 0;
    window_height :: 0;
    application_panel := gui_create_application_window(APPLICATION_NAME_AND_VERSION, window_width, window_height, flags=.START_MINIMIZED|.HAS_NOTIFICATION_ICON|.HIDE_FROM_TASKBAR);

    hook = SetWindowsHookExA(WH_KEYBOARD_LL, global_keyboard_hook, null, 0);
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
                if left_control.consecutive_press_count == 2 && left_control.consecutive_pressed_interval <= double_press_window
                    state = .WAITING_FOR_KEY_RELEASE;
                    active_key_tracker = *left_control;
            }

            if right_control.last_pressed_frame_index == frame.index {
                if right_control.consecutive_press_count == 2 && right_control.consecutive_pressed_interval <= double_press_window
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

            add_key_to_emission_queue(.CTRL, #char "W");
            add_key_to_emission_queue(.CTRL, #char "C");
            state = .SENDING_FETCH_WORD_KEYCODES;
        }

        if state == .SENDING_FETCH_WORD_KEYCODES {
            still_sending := send_next_key_in_emission_queue();
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

                        echo("Asked to check word: %\n", word_to_check);

                        if last_suggested_word  free(last_suggested_word);
                        Spell_Checker.free_spell_check_results(spell_check_results);
                        spell_check_results=, error := Spell_Checker.check_spelling(word_to_check);

                        if error || !spell_check_results || !spell_check_results[0].replacement_suggestions {
                            if error  show_error("Error: %\n", error);
                            last_suggested_word = "";
                        }
                        else {
                            last_suggested_word = copy_string(spell_check_results[0].replacement_suggestions[0]);
                        }
                    }

                    if last_suggested_word {
                        echo("Trying to correct to: %\n", last_suggested_word);
                        os_clipboard_set_text(last_suggested_word);
                        add_key_to_emission_queue(.CTRL, #char "V");
                        state = .SENDING_REPLACE_WORD_KEYCODES;
                    }
                    else {
                        echo("Aborting\n");
                        state = .DORMANT;
                    }
                }
                if clipboard_text  free(clipboard_text);
            }
        }

        if state == .SENDING_REPLACE_WORD_KEYCODES
        || state == .SENDING_NO_REPLACE_KEYCODES {
            still_sending := send_next_key_in_emission_queue();
            if !still_sending  state = .DORMANT;
        }

        reset_temporary_storage();
    }

    gui_shutdown();
}


// Menu item procs

quit :: () {
    should_quit = true;
}

select_language :: (index: int) {
    error := Spell_Checker.init(Spell_Checker.supported_languages[index]);
    if error  show_error("Error: %\n", error);
    refresh_language_menus();
}


// Keyboard hook to monitor keyboard events globally.

hook: HHOOK;
key_events: [128] Keyboard_Event;
key_events_head := 0;
key_events_tail := 0;

Keyboard_Event :: struct {
    event_id: WPARAM;
    using kb_struct: KBDLLHOOKSTRUCT;
}

global_keyboard_hook :: (code: s32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call {
    // This has to be as fast as possible; if we take too long windows will silently unhook us.
    // So, all we do is record the event in a queue, which is later digested in our main loop.
    if code >= 0 {
        ptr := *key_events_head;
        #asm { lock_inc.q [ptr]; }
        index := key_events_head % key_events.count;
        key_event := *key_events[index];
        key_event.event_id = wParam;
        key_event.kb_struct = (cast(*KBDLLHOOKSTRUCT) lParam).*;
    }
    return CallNextHookEx(hook, code, wParam, lParam);
}


// Key tracker records how a single key has changed state over time.

key_trackers: [..] *Key_Tracker;
active_key_tracker: *Key_Tracker;
left_control: Key_Tracker;
right_control: Key_Tracker;

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


// Key emission: sending virtual keypress events

do_not_send_keys_until_after: float64;
inputs_buffer: [..] INPUT;
emission_key_queue: [128] Emission_Key;
emission_key_head: int;
emission_key_tail: int;

Emission_Key :: struct {
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

get_emission_key :: (virtual_code: u16, direction: type_of(Emission_Key.direction)) -> Emission_Key {
    result: Emission_Key;
    result.type = .KEY;
    result.virtual_code = virtual_code;
    result.direction = direction;
    return result;
}

get_emission_delay :: (delay: float64) -> Emission_Key {
    result: Emission_Key;
    result.type = .DELAY;
    result.delay = delay;
    return result;
}

add_to_emission_queue :: (to_emit: Emission_Key) {
    emission_key_head = (emission_key_head + 1) % emission_key_queue.count;
    emission_key_queue[emission_key_head] = to_emit;
}

add_key_to_emission_queue :: inline (keycode: u16) {
    add_key_to_emission_queue(0, keycode);
}

add_key_to_emission_queue :: (flags: Key_Flags, keycode: u16) {
    has_modifier := flags != 0;

    if flags & .CTRL   add_to_emission_queue(get_emission_key(VK_LCONTROL, .DOWN));
    if flags & .SHIFT  add_to_emission_queue(get_emission_key(VK_LSHIFT, .DOWN));
    if flags & .ALT    add_to_emission_queue(get_emission_key(VK_LALT, .DOWN));

    if has_modifier  add_small_delay_to_emission_queue();

    add_to_emission_queue(get_emission_key(keycode, .DOWN));
    add_small_delay_to_emission_queue();
    add_to_emission_queue(get_emission_key(keycode, .UP));

    if has_modifier  add_small_delay_to_emission_queue();

    if flags & .ALT    add_to_emission_queue(get_emission_key(VK_LALT, .UP));
    if flags & .SHIFT  add_to_emission_queue(get_emission_key(VK_LSHIFT, .UP));
    if flags & .CTRL   add_to_emission_queue(get_emission_key(VK_LCONTROL, .UP));

    add_large_delay_to_emission_queue();
}

add_small_delay_to_emission_queue :: () {
    delay := get_emission_delay(small_press_interval);
    add_to_emission_queue(delay);
}

add_large_delay_to_emission_queue :: () {
    delay := get_emission_delay(large_press_interval);
    add_to_emission_queue(delay);
}

send_next_key_in_emission_queue :: () -> still_sending: bool {
    if frame.time < do_not_send_keys_until_after  return true;

    to_emit := emission_key_queue[emission_key_tail];
    emission_key_tail = (emission_key_tail + 1) % emission_key_queue.count;

    if #complete to_emit.type == {
        case .DELAY;
            do_not_send_keys_until_after = frame.time + to_emit.delay;
            return true;

        case .KEY;
            generate_virtual_keystroke(to_emit.virtual_code, to_emit.direction);
            return emission_key_head != emission_key_tail;
    }
}

generate_virtual_keystroke :: (virtual_code: u16, direction: type_of(Emission_Key.direction)) {
    array_reset(*inputs_buffer);
    input := array_add(*inputs_buffer);
    input.* = .{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = virtual_code;
    if direction == .UP  input.ki.dwFlags = KEYEVENTF_KEYUP;

    SendInput(cast(u32) inputs_buffer.count, inputs_buffer.data, size_of(INPUT));
}

generate_virtual_keystrokes :: (s: string) {
    array_reset(*inputs_buffer);
    ctrl_held := false;
    shift_held := false;
    for 0 .. s.count - 1 {
        char := s[it];

        if char == #char "c" {
            input := array_add(*inputs_buffer);
            <<input = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = VK_LCONTROL;
            if ctrl_held  input.ki.dwFlags = KEYEVENTF_KEYUP;
            ctrl_held = !ctrl_held;
        }
        else if char == #char "s" {
            input := array_add(*inputs_buffer);
            <<input = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = VK_LSHIFT;
            if shift_held  input.ki.dwFlags = KEYEVENTF_KEYUP;
            shift_held = !shift_held;
        }
        else {
            // Down
            input := array_add(*inputs_buffer);
            <<input = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = xx char;

            // Up
            input = array_add(*inputs_buffer);
            input.* = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = xx char;
            input.ki.dwFlags = KEYEVENTF_KEYUP;
        }
    }
    assert(!ctrl_held && !shift_held);

    if inputs_buffer.count
        foo := SendInput(xx inputs_buffer.count, inputs_buffer.data, size_of(INPUT));
}


// Misc

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

echo :: (format_string: string, args: .. Any) {
    #if BUILD_MODE == .DEBUG {
        print(format_string, .. args);
    }
}

show_error :: (format_string: string, args: .. Any) {
    echo(format_string, .. args);
}


#scope_file


// Windows stuff

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


// Imports

#import "GUI";

#import "Basic";
#import "Clipboard";
#import "File";
#import "Math";
#import "Strings";
#import "Windows";
#import "Windows_Utf8";

Spell_Checker :: #import "Windows_Spell_Checker";
