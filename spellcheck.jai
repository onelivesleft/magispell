#import "Basic";
#import "Clipboard";
#import "File";
#import "Math";
#import "String";
#import "System";
#import "Windows";
#import "Window_Creation";
#import "Windows_Resources";
#import "Windows_Utf8";
Input :: #import "Input";
Simp :: #import "Simp";

#load "windows_spellchecker.jai";


window: Window_Type;
hook: HHOOK;
font: *Simp.Dynamic_Font;

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

frame_index: int;
frame_time: float64;

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
        consecutive_pressed_interval = frame_time - last_pressed_at;
        last_pressed_frame_index = frame_index;
        last_pressed_at = frame_time;
        consecutive_press_count += 1;
        is_down = true;
    }
    else if key_event.event_id == WM_KEYUP {
        last_released_frame_index = frame_index;
        last_released_at = frame_time;
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

//#run disable_runtime_console();

state: enum {
    DORMANT;
    WAITING_FOR_KEY_RELEASE;
    TRIGGERED;
    SENDING_FETCH_WORD_KEYCODES;
    WAITING_FOR_WORD;
    SENDING_REPLACE_WORD_KEYCODES;
    SENDING_NO_REPLACE_KEYCODES;
}


main :: () {
    read_dictionary();
    init_levenshtein();

    init_key_tracker(*left_control, VK_LCONTROL);
    init_key_tracker(*right_control, VK_RCONTROL);

    font_height :: 16;
    font = Simp.get_font_at_size(".", "KarminaBoldItalic.otf", font_height);

    window_width :: 300;
    window_height :: 100;
    window = create_window(window_width, window_height, "Global Spellchecker");
    //Simp.simp_init(window, window_width, window_height, window_width, window_height);

    hook = SetWindowsHookExA(WH_KEYBOARD_LL, keyboard_hook, null, 0);
    if !hook  exit(1);

    should_quit := false;

    base_color :: Vector4.{.15, .08, .08, 1};
    color: Vector4;


    while !should_quit {
        frame_time = seconds_since_init();
        frame_index += 1;
        did_something := false;

        Input.update_window_events();
        for event: Input.events_this_frame {
            if event.type == .QUIT  should_quit = true;

            if event.type == {
                case .TEXT_INPUT;
                case .DRAG_AND_DROP_FILES;
            }
        }

        if key_events_tail != key_events_head {
            while key_events_tail != key_events_head {
                key_events_tail = (key_events_tail + 1) % key_events.count;
                key_event := key_events[key_events_tail];
                for key_trackers  update_key_tracker(it, key_event);
            }
        }

        if state == .DORMANT {
            if left_control.last_pressed_frame_index == frame_index {
                if left_control.consecutive_press_count == 2 && left_control.consecutive_pressed_interval <= double_press_interval
                    state = .WAITING_FOR_KEY_RELEASE;
                    active_key_tracker = *left_control;
            }

            if right_control.last_pressed_frame_index == frame_index {
                if right_control.consecutive_press_count == 2 && right_control.consecutive_pressed_interval <= double_press_interval
                    state = .WAITING_FOR_KEY_RELEASE;
                    active_key_tracker = *right_control;
            }
        }

        if state == .WAITING_FOR_KEY_RELEASE {
            if active_key_tracker.last_released_frame_index == frame_index
                state = .TRIGGERED;
        }

        if state == .TRIGGERED {
            did_something = true;
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
                fetched_clipboard_at = frame_time;
                state = .WAITING_FOR_WORD;
            }
        }

        if state == .WAITING_FOR_WORD {
            if frame_time - fetched_clipboard_at > clipboard_fetch_timeout {
                show_error("Timed out waiting for clipboard to change.");
                state = .DORMANT;
            }
            else {
                clipboard_text := os_clipboard_get_text();
                if clipboard_text != clipboard_sentinel {
                    print("Asked to check word: %\n", clipboard_text);
                    corrected, score := get_nearest_word(clipboard_text);
                    if score < 3 {
                        print("Trying to correct to: %\n", corrected);
                        os_clipboard_set_text(corrected);
                        add_key(.CTRL, #char "V");
                        state = .SENDING_REPLACE_WORD_KEYCODES;
                    }
                    else {
                        print("Nothing close.\n");
                        os_clipboard_set_text(old_clipboard_value);
                        add_key(VK_RIGHT);
                        state = .DORMANT;
                    }
                    fetched_clipboard_at = 0;
                }
                if clipboard_text  free(clipboard_text);
            }
        }

        if state == .SENDING_REPLACE_WORD_KEYCODES
        || state == .SENDING_NO_REPLACE_KEYCODES {
            still_sending := send_next_key();
            if !still_sending  state = .DORMANT;
        }

        if did_something  color = .{1, 1, 1, 1};
        else              color = lerp(color, base_color, 0.1);

        Simp.clear_render_target(color.x, color.y, color.z, color.w);

        //y := window_height;
        //y -= (font_height + 2);
        //Simp.prepare_text(font, text);
        //Simp.draw_prepared_text(font, 0, y, .{1,1,1,1});

        Simp.swap_buffers(window);

        reset_temporary_storage();
        if state == .DORMANT && !should_quit
            sleep_milliseconds(1);
    }
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
    if frame_time < do_not_send_keys_until_after  return true;

    to_emit := key_emit_queue[key_emit_tail];
    key_emit_tail = (key_emit_tail + 1) % key_emit_queue.count;

    if #complete to_emit.type == {
        case .DELAY;
            do_not_send_keys_until_after = frame_time + to_emit.delay;
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
CoUninitialize :: () -> void    #foreign Ole32;
CoInitializeEx :: (pvReserved: *void, dwCoInit: DWORD) -> HRESULT #foreign Ole32;
CoCreateInstance :: (rclsid: REFCLSID, pUnkOuter: *IUnknown, dwClsContext: CLSCTX, riid: REFIID, ppv: **void) -> HRESULT #foreign Ole32;
CoTaskMemFree :: (ptr: *void) #foreign Ole32;

using CLSCTX :: enum_flags u32 {
    CLSCTX_INPROC_SERVER    :: 0x1;
    CLSCTX_INPROC_HANDLER   :: 0x2;
    CLSCTX_LOCAL_SERVER     :: 0x4;
    CLSCTX_INPROC_SERVER16  :: 0x8;
    CLSCTX_REMOTE_SERVER    :: 0x10;
    CLSCTX_INPROC_HANDLER16 :: 0x20;
    CLSCTX_RESERVED1        :: 0x40;
    CLSCTX_RESERVED2        :: 0x80;
    CLSCTX_RESERVED3        :: 0x100;
    CLSCTX_RESERVED4        :: 0x200;
    CLSCTX_NO_CODE_DOWNLOAD :: 0x400;
    CLSCTX_RESERVED5        :: 0x800;
    CLSCTX_NO_CUSTOM_MARSHAL    :: 0x1000;
    CLSCTX_ENABLE_CODE_DOWNLOAD :: 0x2000;
    CLSCTX_NO_FAILURE_LOG       :: 0x4000;
    CLSCTX_DISABLE_AAA          :: 0x8000;
    CLSCTX_ENABLE_AAA           :: 0x10000;
    CLSCTX_FROM_DEFAULT_CONTEXT :: 0x20000;
    CLSCTX_ACTIVATE_X86_SERVER  :: 0x40000;
    CLSCTX_ACTIVATE_32_BIT_SERVER   :: CLSCTX_ACTIVATE_X86_SERVER;
    CLSCTX_ACTIVATE_64_BIT_SERVER   :: 0x80000;
    CLSCTX_ENABLE_CLOAKING          :: 0x100000;
    CLSCTX_APPCONTAINER             :: 0x400000;
    CLSCTX_ACTIVATE_AAA_AS_IU       :: 0x800000;
    CLSCTX_RESERVED6                :: 0x1000000;
    CLSCTX_ACTIVATE_ARM32_SERVER    :: 0x2000000;
    CLSCTX_PS_DLL                   :: 0x80000000;

    CLSCTX_INPROC   :: CLSCTX_INPROC_SERVER|CLSCTX_INPROC_HANDLER;
    CLSCTX_ALL      :: CLSCTX_INPROC_SERVER|CLSCTX_INPROC_HANDLER|CLSCTX_LOCAL_SERVER|CLSCTX_REMOTE_SERVER;
    CLSCTX_SERVER   :: CLSCTX_INPROC_SERVER|CLSCTX_LOCAL_SERVER|CLSCTX_REMOTE_SERVER;
}

user32 :: #system_library "user32";
kernel32 :: #system_library "kernel32";
Ole32 :: #system_library "Ole32";

REFCLSID :: *IID;
WH_KEYBOARD :: 2;
WH_KEYBOARD_LL :: 13;
COINIT_MULTITHREADED :: 0;

word_blob: string;
words: [] string;
lower_words: [] string;

read_dictionary :: () {
    data := read_entire_file("words.txt");
    builder: String_Builder;
    lengths: [..] int;
    for word: split(data, "\n") {
        trimmed := trim(word);
        append(*builder, trimmed);
        to_lower_in_place(trimmed);
        append(*builder, trimmed);
        array_add(*lengths, trimmed.count);
    }

    word_blob = builder_to_string(*builder);
    words = NewArray(lengths.count, string);
    lower_words = NewArray(lengths.count, string);
    offset := 0;
    for length: lengths {
        words[it_index].data = (cast(*u8)word_blob.data) + offset;
        words[it_index].count = length;
        offset += length;

        lower_words[it_index].data = (cast(*u8)word_blob.data) + offset;
        lower_words[it_index].count = length;
        offset += length;
    }
    array_free(lengths);
    free(data);
}

levenshtein_ascending: [128] s16;
levenshtein_buffer: [128] s16;
levenshtein_costs: [] s16;

init_levenshtein :: () {
    levenshtein_costs.data = levenshtein_buffer.data;
    for 0 .. levenshtein_ascending.count - 1
        levenshtein_ascending[it] = cast(s16) it;
}

levenshtein_distance :: (s1: string, s2: string) -> int {
    if !s1  return s2.count;
    if !s2  return s1.count;

    levenshtein_costs.count = s2.count + 1;
    memcpy(levenshtein_costs.data, levenshtein_ascending.data, levenshtein_costs.count * size_of(type_of(levenshtein_costs[0])));

    for i: 0 .. cast(s16) s1.count - 1 {
        c1 := s1[i];
        levenshtein_costs[0] = i + 1;
        corner := i;
        for j: 0 .. s2.count - 1 {
            c2 := s2[j];
            upper := levenshtein_costs[j + 1];
            if c1 == c2 {
                levenshtein_costs[j + 1] = corner;
            }
            else {
                t := ifx upper < corner then upper else corner;
                levenshtein_costs[j + 1] = 1 + ifx levenshtein_costs[j] < t then levenshtein_costs[j] else t;
            }
            corner = upper;
        }
    }

    return levenshtein_costs[s2.count];
}

get_nearest_word :: (s: string) -> string, score: int {
    nearest_word: string;
    nearest_score := 999999999;
    lower_s := copy_temporary_string(s);
    to_lower_in_place(lower_s);
    caseless_match: string;
    for word: words {
        if lower_s == lower_words[it_index]
            caseless_match = word;
        score := levenshtein_distance(s, word);
        if score < nearest_score {
            nearest_score = score;
            nearest_word = word;
        }
    }
    if nearest_score == 0  return s, 0;
    if caseless_match  return caseless_match, 0;
    return nearest_word, nearest_score;
}