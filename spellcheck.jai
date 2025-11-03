#if BUILD_MODE == .RELEASE
    APPLICATION_NAME :: "Magispell";
else
    APPLICATION_NAME :: "Magispell (DEBUG)";
VERSION :: "v1.00";
APPLICATION_NAME_AND_VERSION :: #run sprint("% %", APPLICATION_NAME, VERSION);
CONFIG_REGISTRY_SUBKEY :: "Software\\One Lives Left\\Magispell";
// BUILD_MODE : enum { DEBUG; RELEASE; NO_OUTPUT; }; is inserted by build.jai
USE_DEBUG_ALLOCATOR : enum { NONE; UNMAPPING; OVERWRITING; } : .NONE;

// TODO
// [x] Switch to windows spellchecker
// [x] Select dictionary
// [x] Menu upgrades
//  [x] Move preferred languages to main menu, above the fold
//  [x] Section breaks
//  [x] Checkmarks
// [x] Disallow spaces in answers (we are just correcting single words)
// [x] Cycle suggestions on subsequent presses
// [ ] User hotkeys for word selection
//  [ ] Per-process specific?
// [ ] User select word keystring
//  [ ] Initially: left/right/both ctrl + double/triple press?
//  [ ] Subsequently: choose hotkey
// [x] Popup suggestions menu
// [x] Store config
// [ ] Maybe allow user to check currently selected text?
// [x] SFX
// [x] Toasts (messages, errors)

play_audio := true;
current_language: string;

spell_check_results: [] Spell_Checker.Spell_Check_Results;
word_to_check: string;
received_word: string;
last_suggested_word: string;

replacement_suggestions_menu: [..] Menu_Item;
user_preferred_languages: [..] Menu_Item;
other_supported_languages: [..] Menu_Item;

consecutive_press_intervals :: s32.[100, 200, 400, 800];
default_consecutive_press_interval_index :: 1;
consecutive_press_interval_ms := consecutive_press_intervals[default_consecutive_press_interval_index];
consecutive_press_interval := cast(float64)consecutive_press_intervals[default_consecutive_press_interval_index] / 1000.0;

large_press_intervals :: s32.[20, 40, 80, 160];
default_large_press_interval_index :: 0;
large_press_interval_ms := large_press_intervals[default_large_press_interval_index];
large_press_interval := cast(float64) large_press_intervals[default_large_press_interval_index] / 1000.0;
small_press_interval := cast(float64) large_press_intervals[default_large_press_interval_index] / 2000.0;

last_key_event_at: float64;
spell_check_triggered_key_press_at: float64;
suggestion_mode: enum { CYCLE; MENU; }
sleep_after_idle_delay : float64 : 5.0;

old_clipboard_value := "";
fetched_clipboard_at: float64;
clipboard_fetch_timeout :: 2.0;

state: enum {
    DORMANT;
    WAITING_FOR_TRIPLE_PRESS;
    WAITING_FOR_KEY_RELEASE;
    TRIGGERED;
    SENDING_FETCH_WORD_KEYCODES;
    WAITING_FOR_WORD;
    RECEIVED_WORD;
    SENDING_REPLACE_WORD_KEYCODES;
    SENDING_NO_REPLACE_KEYCODES;
}

should_quit := false;


main :: () {
    #if BUILD_MODE == .DEBUG && USE_DEBUG_ALLOCATOR {
        #if USE_DEBUG_ALLOCATOR == .UNMAPPING {
            UA :: #import "Unmapping_Allocator";
            context.allocator = UA.get_unmapping_allocator();
        }
        else #if USE_DEBUG_ALLOCATOR == .OVERWRITING {
            OA :: #import "Overwriting_Allocator";
            context.allocator = OA.get_overwriting_allocator();
        }
    }

    read_config();

    error := Spell_Checker.init(current_language);
    defer Spell_Checker.deinit();
    refresh_language_menus();

    init_key_tracker(*left_control, VK_LCONTROL);
    init_key_tracker(*right_control, VK_RCONTROL);

    window_width :: 512;
    window_height :: 512;
    application_panel := gui_create_application_window(APPLICATION_NAME_AND_VERSION, window_width, window_height, flags=.START_MINIMIZED|.HAS_NOTIFICATION_ICON|.HIDE_FROM_TASKBAR);

    hook = SetWindowsHookExA(WH_KEYBOARD_LL, global_keyboard_hook, null, 0);
    if !hook  exit(1);

    base_color :: Vector4.{.15, .08, .08, 1};
    color: Vector4;

    while !should_quit {
        should_quit = gui_begin_frame();

        if key_events_tail != key_events_head {
            last_key_event_at = frame.time;
            while key_events_tail != key_events_head {
                index := (key_events_tail + 1) % key_events.count;
                key_event := key_events[index];
                for key_trackers  update_key_tracker(it, key_event);
                key_events_tail = index;
            }
        }

        frame.no_sleep = frame.time < last_key_event_at + sleep_after_idle_delay;

        if gui_notification_icon_was_clicked() {
            gui_system_menu(
                .[ menu_item(APPLICATION_NAME, .IS_DEFAULT), menu_item(VERSION),  ],
                user_preferred_languages,
                .[ menu_item("Sound", toggle_audio, ifx play_audio then .IS_CHECKED),
                   sub_menu("Options...", .[
                        menu_item("Key Send Interval", .IS_DISABLED),
                        menu_item("20ms",  set_key_send_interval, 0, ifx (large_press_interval_ms==large_press_intervals[0]) then .IS_CHECKED),
                        menu_item("40ms",  set_key_send_interval, 1, ifx (large_press_interval_ms==large_press_intervals[1]) then .IS_CHECKED),
                        menu_item("80ms",  set_key_send_interval, 2, ifx (large_press_interval_ms==large_press_intervals[2]) then .IS_CHECKED),
                        menu_item("160ms", set_key_send_interval, 3, ifx (large_press_interval_ms==large_press_intervals[3]) then .IS_CHECKED),
                        menu_separator(),
                        menu_item("Double Press Interval", .IS_DISABLED),
                        menu_item("100ms", set_consecutive_press_interval, 0, ifx (consecutive_press_interval_ms==consecutive_press_intervals[0]) then .IS_CHECKED),
                        menu_item("200ms", set_consecutive_press_interval, 1, ifx (consecutive_press_interval_ms==consecutive_press_intervals[1]) then .IS_CHECKED),
                        menu_item("400ms", set_consecutive_press_interval, 2, ifx (consecutive_press_interval_ms==consecutive_press_intervals[2]) then .IS_CHECKED),
                        menu_item("800ms", set_consecutive_press_interval, 3, ifx (consecutive_press_interval_ms==consecutive_press_intervals[3]) then .IS_CHECKED),
                   ]),
                ],
                .[ menu_item("Exit", quit, icon=.SUB_MENU_CLOSE) ],
            );
        }

        if state == .DORMANT {
            if key_tracker_pressed(left_control, consecutive_presses=2) {
               state = .WAITING_FOR_TRIPLE_PRESS;
               active_key_tracker = *left_control;
               spell_check_triggered_key_press_at = frame.time;
               suggestion_mode = .CYCLE;
            }
            else if key_tracker_pressed(right_control, consecutive_presses=2) {
               state = .WAITING_FOR_TRIPLE_PRESS;
               active_key_tracker = *right_control;
               spell_check_triggered_key_press_at = frame.time;
               suggestion_mode = .CYCLE;
            }
        }

        if state == .WAITING_FOR_TRIPLE_PRESS {
            if frame.time > spell_check_triggered_key_press_at + consecutive_press_interval {
                state = ifx !active_key_tracker.is_down then .TRIGGERED else .WAITING_FOR_KEY_RELEASE;
            }
            else if key_tracker_pressed(active_key_tracker, consecutive_presses=3) {
                suggestion_mode = .MENU;
                state = ifx !active_key_tracker.is_down then .TRIGGERED else .WAITING_FOR_KEY_RELEASE;
            }
        }

        if state == .WAITING_FOR_KEY_RELEASE {
            if !active_key_tracker.is_down
                state = .TRIGGERED;
        }

        if state == .TRIGGERED {
            if old_clipboard_value  free(old_clipboard_value);
            old_clipboard_value = os_clipboard_get_text();
            os_clipboard_set_text("");

            add_to_key_emission_queue(.SELECT_WORD);
            add_to_key_emission_queue(.CLIPBOARD_COPY);

            state = .SENDING_FETCH_WORD_KEYCODES;
        }

        if state == .SENDING_FETCH_WORD_KEYCODES {
            still_sending := maybe_send_next_key_in_emission_queue();
            if !still_sending {
                fetched_clipboard_at = frame.time;
                state = .WAITING_FOR_WORD;
            }
        }

        if state == .WAITING_FOR_WORD {
            clipboard_text := os_clipboard_get_text();

            if clipboard_text {
                if !contains(clipboard_text, #char " ") {
                    set_string_with_copy(*received_word, clipboard_text);
                    state = .RECEIVED_WORD;
                }
                else {
                    state = .DORMANT;
                }

                free(clipboard_text);
            }
            else if frame.time - fetched_clipboard_at > clipboard_fetch_timeout {
                show_error("Timed out waiting for clipboard to change.\n");
                state = .DORMANT;
            }
        }

        if state == .RECEIVED_WORD {
            fetched_clipboard_at = 0;
            found_received_word := false;
            replaced_with_original_word := false;

            if spell_check_results && spell_check_results[0].replacement_suggestions && last_suggested_word && received_word == last_suggested_word {
                if received_word == word_to_check {
                    set_string_with_copy(*last_suggested_word, spell_check_results[0].replacement_suggestions[0]);
                    found_received_word = true;
                }
                else {
                    set_last_suggested_word := false;
                    for result: spell_check_results {
                        for suggestion: result.replacement_suggestions {
                            if found_received_word {
                                set_string_with_copy(*last_suggested_word, suggestion);
                                set_last_suggested_word = true;
                                break result;
                            }
                            else if suggestion == received_word {
                                found_received_word = true;
                            }
                        }
                    }
                    if found_received_word && !set_last_suggested_word {
                        set_string_with_copy(*last_suggested_word, word_to_check);
                        replaced_with_original_word = true;
                    }
                }
            }

            if !found_received_word {
                set_string_with_copy(*word_to_check, received_word);

                echo("Asked to check word: %\n", word_to_check);

                Spell_Checker.free_spell_check_results(spell_check_results);
                spell_check_results=, error := Spell_Checker.check_spelling(word_to_check, single_word_suggestions_only=true);

                echo("Suggestions:\n");
                for spell_check_results
                    for suggestion: it.replacement_suggestions
                        echo(" [%] <%>\n", suggestion, cast(*void)suggestion.data);

                if error || !spell_check_results || !spell_check_results[0].replacement_suggestions {
                    if error  show_error("Error: %\n", error);
                    set_string_directly(*last_suggested_word, "");
                }
                else {
                    set_string_with_copy(*last_suggested_word, spell_check_results[0].replacement_suggestions[0]);
                }
            }

            if last_suggested_word {
                if #complete suggestion_mode == {
                    case .CYCLE;
                        echo("--- Cycling ---\n");
                        echo("Trying to correct to: %\n", last_suggested_word);
                        play_sfx(ifx replaced_with_original_word then .REPLACED_WITH_ORIGINAL_WORD else .REPLACED_WITH_SUGGESTION);
                        os_clipboard_set_text(last_suggested_word);
                        add_to_key_emission_queue(.CLIPBOARD_PASTE);
                        state = .SENDING_REPLACE_WORD_KEYCODES;

                    case .MENU;
                        echo("--- Showing popup menu ---\n");
                        refresh_replacement_suggestions_menu();
                        gui_system_menu(replacement_suggestions_menu);
                        assert(state == .SENDING_REPLACE_WORD_KEYCODES || state == .SENDING_NO_REPLACE_KEYCODES);
                }
            }
            else {
                echo("No suggestions available\n");
                play_sfx(.REPLACED_WITH_ORIGINAL_WORD);
                add_to_key_emission_queue(.UNSELECT_WORD);
                state = .SENDING_NO_REPLACE_KEYCODES;
            }
        }

        if state == .SENDING_REPLACE_WORD_KEYCODES
        || state == .SENDING_NO_REPLACE_KEYCODES {
            still_sending := maybe_send_next_key_in_emission_queue();
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
    set_string_directly(*current_language, Spell_Checker.supported_languages[index]);
    write_config();
    refresh_language_menus();
}

select_replacement_suggestion :: (index: int) {
    if index == cast(int) Replacement_Suggestions_Menu_Id.CANCEL {
        add_to_key_emission_queue(.UNSELECT_WORD);
        state = .SENDING_NO_REPLACE_KEYCODES;
        return;
    }

    replace_with_original_word := (index == cast(int) Replacement_Suggestions_Menu_Id.USE_WORD_TO_CHECK);
    if replace_with_original_word {
        set_string_with_copy(*last_suggested_word, word_to_check);
        play_sfx(.REPLACED_WITH_ORIGINAL_WORD);
    }
    else {
        suggestion_index := 0;
        for result: spell_check_results {
            for suggestion: result.replacement_suggestions {
                if suggestion_index == index {
                    set_string_with_copy(*last_suggested_word, suggestion);
                    break result;
                }
                suggestion_index += 1;
            }
        }
        play_sfx(.REPLACED_WITH_SUGGESTION);
    }

    echo("Trying to correct to: %\n", last_suggested_word);
    os_clipboard_set_text(last_suggested_word);
    add_to_key_emission_queue(.CLIPBOARD_PASTE);
    state = .SENDING_REPLACE_WORD_KEYCODES;
}

toggle_audio :: () {
    play_audio = !play_audio;
    if play_audio  play_sfx(.REPLACED_WITH_SUGGESTION);
    write_config();
}

set_key_send_interval :: (index: int) {
    large_press_interval_ms = large_press_intervals[index];
    large_press_interval = cast(float64) large_press_interval_ms / 1000.0;
    small_press_interval = large_press_interval / 2;
    write_config();
}

set_consecutive_press_interval :: (index: int) {
    consecutive_press_interval_ms = consecutive_press_intervals[index];
    consecutive_press_interval = cast(float64) consecutive_press_interval_ms / 1000.0;
    write_config();
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
        index := (key_events_head + 1 ) % key_events.count;
        key_event := *key_events[index];
        key_event.event_id = wParam;
        key_event.kb_struct = (cast(*KBDLLHOOKSTRUCT) lParam).*;
        key_events_head = index;
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
        if consecutive_pressed_interval <= consecutive_press_interval
            consecutive_press_count += 1;
        else
            consecutive_press_count = 1;
        last_pressed_frame_index = frame.index;
        last_pressed_at = frame.time;
        is_down = true;
    }
    else if key_event.event_id == WM_KEYUP {
        last_released_frame_index = frame.index;
        last_released_at = frame.time;
        is_down = false;
    }
}

key_tracker_pressed :: (key_tracker: Key_Tracker, consecutive_presses := 0) -> bool {
    return key_tracker.last_pressed_frame_index == frame.index
        && (consecutive_presses == 0 || key_tracker.consecutive_press_count == consecutive_presses);
}


// Key emission: sending virtual keypress events

do_not_send_keys_until_after: float64;
inputs_buffer: [..] INPUT;
emission_key_queue: [128] Emission_Key;
emission_key_write_index: int;
emission_key_read_index: int;

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

Client_Action :: enum {
    SELECT_WORD;
    CLIPBOARD_COPY;
    CLIPBOARD_PASTE;
    UNSELECT_WORD;
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

add_to_key_emission_queue :: (to_emit: Emission_Key) {
    emission_key_queue[emission_key_write_index] = to_emit;
    emission_key_write_index = (emission_key_write_index + 1) % emission_key_queue.count;
}

add_to_key_emission_queue :: inline (keycode: u16) {
    add_to_key_emission_queue(0, keycode);
}

add_to_key_emission_queue :: (flags: Key_Flags, keycode: u16) {
    has_modifier := flags != 0;

    if emission_queue_ends_with_key_press()
        add_to_key_emission_queue(delay=large_press_interval);

    if flags & .CTRL   add_to_key_emission_queue(get_emission_key(VK_LCONTROL, .DOWN));
    if flags & .SHIFT  add_to_key_emission_queue(get_emission_key(VK_LSHIFT, .DOWN));
    if flags & .ALT    add_to_key_emission_queue(get_emission_key(VK_LALT, .DOWN));

    if has_modifier  add_to_key_emission_queue(delay=small_press_interval);

    add_to_key_emission_queue(get_emission_key(keycode, .DOWN));
    add_to_key_emission_queue(delay=small_press_interval);
    add_to_key_emission_queue(get_emission_key(keycode, .UP));

    if has_modifier  add_to_key_emission_queue(delay=small_press_interval);

    if flags & .ALT    add_to_key_emission_queue(get_emission_key(VK_LALT, .UP));
    if flags & .SHIFT  add_to_key_emission_queue(get_emission_key(VK_LSHIFT, .UP));
    if flags & .CTRL   add_to_key_emission_queue(get_emission_key(VK_LCONTROL, .UP));
}

add_to_key_emission_queue :: (delay: float64) {
    add_to_key_emission_queue(get_emission_delay(delay));
}

add_to_key_emission_queue :: (action: Client_Action) {
    if #complete action == {
        case .SELECT_WORD;      add_to_key_emission_queue(.CTRL, #char "W");
        case .CLIPBOARD_COPY;   add_to_key_emission_queue(.CTRL, #char "C");
        case .CLIPBOARD_PASTE;  add_to_key_emission_queue(.CTRL, #char "V");
        case .UNSELECT_WORD;    add_to_key_emission_queue(VK_RIGHT);
    }
}

emission_queue_ends_with_key_press :: () -> bool {
    if emission_key_read_index == emission_key_write_index
        return false;

    prior_index := emission_key_write_index - 1;
    if prior_index < 0  prior_index += emission_key_queue.count;
    return emission_key_queue[prior_index].type == .KEY;
}

maybe_send_next_key_in_emission_queue :: () -> still_sending: bool {
    if frame.time < do_not_send_keys_until_after  return true;

    assert(emission_key_write_index != emission_key_read_index);
    to_emit := emission_key_queue[emission_key_read_index];
    emission_key_read_index = (emission_key_read_index + 1) % emission_key_queue.count;

    if #complete to_emit.type == {
        case .DELAY;
            do_not_send_keys_until_after = frame.time + to_emit.delay;
            return true;

        case .KEY;
            generate_virtual_keystroke(to_emit.virtual_code, to_emit.direction);
            return emission_key_write_index != emission_key_read_index;
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
            input.* = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = VK_LCONTROL;
            if ctrl_held  input.ki.dwFlags = KEYEVENTF_KEYUP;
            ctrl_held = !ctrl_held;
        }
        else if char == #char "s" {
            input := array_add(*inputs_buffer);
            input.* = .{};
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = VK_LSHIFT;
            if shift_held  input.ki.dwFlags = KEYEVENTF_KEYUP;
            shift_held = !shift_held;
        }
        else {
            // Down
            input := array_add(*inputs_buffer);
            input.* = .{};
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


// Config

CONFIG_CURRENT_LANGUAGE ::  "Current Language";
CONFIG_SOUND ::             "Sound";
CONFIG_KEY_SEND_INTERVAL :: "Key Send Interval (ms)";
CONFIG_CONSECUTIVE_PRESS_INTERVAL :: "Double Press Interval (ms)";

with_registry_config :: (mode: enum { READ; WRITE; }) -> HKEY #expand {
    hkey: HKEY;
    error := RegCreateKeyExA(HKEY_CURRENT_USER, CONFIG_REGISTRY_SUBKEY, 0, null, REG_OPTION_NON_VOLATILE, cast(u32) ifx mode == .WRITE then KEY_SET_VALUE else KEY_QUERY_VALUE, 0, *hkey, null);
    if error  `return;
    `defer RegCloseKey(hkey);
    return hkey;
}

write_config :: () {
    hkey := with_registry_config(.WRITE);

    error := write_config_option(hkey, CONFIG_CURRENT_LANGUAGE, current_language);
    if error  show_error("Error: %\n", error);

    error = write_config_option(hkey, CONFIG_SOUND, play_audio);
    if error  show_error("Error: %\n", error);

    error = write_config_option(hkey, CONFIG_KEY_SEND_INTERVAL, large_press_interval_ms);
    if error  show_error("Error: %\n", error);

    error = write_config_option(hkey, CONFIG_CONSECUTIVE_PRESS_INTERVAL, consecutive_press_interval_ms);
    if error  show_error("Error: %\n", error);
}

write_config_option :: (hkey: HKEY, $$name: string, value: $T) -> LSTATUS {
    result: LSTATUS;
    #if T == string {
        result = RegSetValueExA(hkey, null_terminated(name), 0, xx REG_SZ, null_terminated(value), cast(u32) (value.count + 1));
    }
    else #if T == bool || T == s32 {
        dword := cast(u32) value;
        result = RegSetValueExA(hkey, null_terminated(name), 0, xx REG_DWORD, cast(*u8) *dword, size_of(type_of(dword)));
    }
    else {
        #assert false;
    }

    return result;
}

read_config :: () {
    hkey := with_registry_config(.READ);
    set_string_directly(*current_language, read_config_option(hkey, CONFIG_CURRENT_LANGUAGE, current_language));
    play_audio = read_config_option(hkey, CONFIG_SOUND, play_audio);

    large_press_interval_ms = read_config_option(hkey, CONFIG_KEY_SEND_INTERVAL, large_press_interval_ms);
    large_press_interval = cast(float64) large_press_interval_ms / 1000.0;
    small_press_interval = large_press_interval / 2;

    consecutive_press_interval_ms = read_config_option(hkey, CONFIG_CONSECUTIVE_PRESS_INTERVAL, consecutive_press_interval_ms);
    consecutive_press_interval = cast(float64) consecutive_press_interval_ms / 1000.0;
}

read_config_option :: (hkey: HKEY, name: string, default_value: $T) -> T {
    value := default_value;
    null_terminated_name := null_terminated(name);

    #if T == string {
        type : u32 = REG_SZ;
        byte_count: u32;
        error := RegQueryValueExA(hkey, null_terminated_name, null, *type, null, *byte_count);
        if error  return value;

        buffer := NewArray(byte_count, u8);
        error = RegQueryValueExA(hkey,  null_terminated_name, null, *type, buffer.data, *byte_count);
        if error  return value;

        value.data = buffer.data;
        value.count = buffer.count - 1; // Null terminated
    }
    else #if T == bool || T == s32 {
        type : u32 = REG_DWORD;
        dword: u32;
        byte_count: u32 = size_of(type_of(dword));
        error := RegQueryValueExA(hkey,  null_terminated_name, null, *type, cast(*u8) *dword, *byte_count);
        if error  return value;

        value = cast(T) dword;
    }
    else {
        #assert false;
    }

    return value;
}


// Audio

sfx: enum {
    NONE;
    REPLACED_WITH_SUGGESTION;
    REPLACED_WITH_ORIGINAL_WORD;
}

sound_raw_data : [#run enum_highest_value(type_of(sfx)) + 1] string : .[
    "",                                   // .NONE
    #run bake_file("smb_kick.wav"),       // .REPLACED_WITH_SUGGESTION
    #run bake_file("smb_kick_start.wav"), // .REPLACED_WITH_ORIGINAL_WORD
];

play_sfx :: (id: type_of(sfx)) {
    if play_audio
        sndPlaySoundA(sound_raw_data[id].data, SND_MEMORY|SND_ASYNC|SND_NODEFAULT|SND_SYSTEM);
}


// Misc

set_string_with_copy :: (s: *string, value: string) {
    if s && s.*  free(s.*);
    s.* = copy_string(value);
}

set_string_directly :: (s: *string, value: string) {
    s.* = value;
}

refresh_language_menus :: () {
    array_reset(*user_preferred_languages);
    array_reset(*other_supported_languages);
    for Spell_Checker.supported_languages {
        is_checked := it == Spell_Checker.current_language;
        menu := ifx it_index < Spell_Checker.user_preferred_language_count || is_checked
                then *user_preferred_languages
                else *other_supported_languages;
        array_add(menu, menu_item(it, select_language, it_index, ifx is_checked then .IS_CHECKED));
    }
    array_add(*user_preferred_languages, sub_menu("More...", other_supported_languages));
}

Replacement_Suggestions_Menu_Id :: enum {
    USE_WORD_TO_CHECK :: -1;
    CANCEL :: -2;
}

refresh_replacement_suggestions_menu :: () {
    array_reset(*replacement_suggestions_menu);
    array_add(*replacement_suggestions_menu, menu_item(word_to_check, select_replacement_suggestion, cast(int) Replacement_Suggestions_Menu_Id.USE_WORD_TO_CHECK, .IS_DEFAULT));
    array_add(*replacement_suggestions_menu, menu_separator());
    index := 0;
    for result: spell_check_results {
        for suggestion: result.replacement_suggestions {
            array_add(*replacement_suggestions_menu, menu_item(suggestion, select_replacement_suggestion, index));
            index += 1;
        }
    }
    array_add(*replacement_suggestions_menu, menu_separator());
    array_add(*replacement_suggestions_menu, menu_item("Cancel", select_replacement_suggestion, cast(int) Replacement_Suggestions_Menu_Id.CANCEL));
}

echo :: (format_string: string, args: .. Any) {
    #if BUILD_MODE == .DEBUG {
        print(format_string, .. args);
    }
}

show_message :: (format_string: string, args: .. Any) {
    echo(format_string, args);
    gui_notification_message(APPLICATION_NAME, tprint(format_string, args));
}

show_error :: (format_string: string, args: .. Any) {
    echo(format_string, args);
    gui_notification_message(APPLICATION_NAME, tprint(format_string, args), .ERROR);
}

null_terminated :: ($$s: string) -> *u8 {
    #if is_constant(s) {
        return s.data;
    }
    else {
        result : string = ---;
        result.count = s.count + 1;
        result.data = alloc(result.count,, temp);

        memcpy(result.data, s.data, s.count);
        result[s.count] = #char "\0";

        return result.data;
    }
}

contains :: (haystack: string, needle: u8) -> bool {
    for 0 .. haystack.count - 1
        if haystack[it] == needle
            return true;
    return false;
}

bake_file :: (filename: string) -> string #compile_time {
    #if BUILD_MODE != .NO_OUTPUT {
        file :: #import "File";
        full_name := sprint("%media/%", #filepath, filename);
        file_data, success := file.read_entire_file(full_name);
        assert(success, "Failed to read %\n", full_name);
        return file_data;
    }
    else {
        return "";
    }
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

FreeConsole :: () -> bool #foreign kernel32;
GetKeyboardState :: (lpKeyState: *[256] u8) -> bool #foreign user32;
SetWindowsHookExA :: (idHook: s32,  lpfn: HOOKPROC, hmod: HINSTANCE, dwThreadId: s32) -> HHOOK #foreign user32;
CallNextHookEx :: (hhk: HHOOK, nCode: s32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #foreign user32;
SendInput :: (cInputs: u32, pInputs: *INPUT, cbSize: s32) -> u32 #foreign user32;
sndPlaySoundA :: (lpszSound: *void, flags: u32) #foreign winmm;
RegCreateKeyExA :: (hKey: HKEY, lpSubKey: LPCSTR, Reserved: DWORD, lpClass: LPSTR, dwOptions: DWORD, samDesired: REGSAM, lpSecurityAttributes: LPSECURITY_ATTRIBUTES, phkResult: *HKEY, lpdwDisposition: *s32) -> LSTATUS #foreign advapi32;
RegSetValueExA :: (hkey: HKEY, lpSubKey: *u8, Reserved: DWORD, dwType: DWORD, lpData: *u8, cbData: DWORD) -> LSTATUS #foreign advapi32;

advapi32 :: #system_library "Advapi32";
kernel32 :: #system_library "kernel32";
user32 :: #system_library "user32";
winmm :: #system_library "winmm";

HHOOK :: *void;
WH_KEYBOARD :: 2;
WH_KEYBOARD_LL :: 13;

LPSECURITY_ATTRIBUTES :: u64;
REG_OPTION_NON_VOLATILE :: 0x00000000;
KEY_SET_VALUE :: 0x0002;

SND_ASYNC ::     0x000001;
SND_NODEFAULT :: 0x000002;
SND_MEMORY ::    0x000004;
SND_SYSTEM ::    0x200000;


// Imports

#import "GUI";

#import "Basic";
#import "Clipboard";
#import "File";
#import "Math";
#import "Windows";
#import "Windows_Registry";
#import "Windows_Utf8";

Sound :: #import "Sound_Player";
Spell_Checker :: #import "Windows_Spell_Checker";
