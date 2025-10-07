#import "Basic";
#import "Clipboard";
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
double_press_interval :: 0.2;

old_clipboard_value := "";
clipboard_sentinel :: "!#@";
fetched_clipboard_at: float64;
clipboard_fetch_timeout :: 2.0;

//#run disable_runtime_console();

main :: () {

    print("running spellcheck test\n");
    err := test_spellcheck();
    print("err = %\n", err);

    font_height :: 16;
    font = Simp.get_font_at_size(".", "KarminaBoldItalic.otf", font_height);

    window_width :: 300;
    window_height :: 100;
    window = create_window(window_width, window_height, "Global Spellchecker");
    Simp.simp_init(window, window_width, window_height, window_width, window_height);

    hook = SetWindowsHookExA(WH_KEYBOARD_LL, keyboard_hook, null, 0);
    if !hook  exit(1);

    should_quit := false;

    base_color :: Vector4.{.15, .08, .08, 1};
    color: Vector4;

    text: string;

    while !should_quit {
        now := get_time();
        did_something := false;

        Input.update_window_events();
        for event: Input.events_this_frame {
            if event.type == .QUIT  should_quit = true;

            if event.type == {
                case .TEXT_INPUT;
                case .DRAG_AND_DROP_FILES;
            }
        }

        color = lerp(color, base_color, 0.1);


        if key_events_tail != key_events_head {
            while key_events_tail != key_events_head {
                key_events_tail = (key_events_tail + 1) % key_events.count;
                key_event := key_events[key_events_tail];
                if key_event.event_id == WM_KEYUP {
                    if key_event.vkCode == VK_LCONTROL || key_event.vkCode == VK_RCONTROL {
                        if last_control_press {
                            if now - last_control_press < double_press_interval {
                                did_something = true;
                                color = .{1, 1, 1, 1};
                                if text  free(text);
                                text = sprint("%", now);
                                if old_clipboard_value  free(old_clipboard_value);
                                old_clipboard_value = os_clipboard_get_text();
                                os_clipboard_set_text(clipboard_sentinel);
                                generate_keystrokes("cWCc");
                                fetched_clipboard_at = now;
                                last_control_press = 0;
                            }
                            else {
                                last_control_press = now;
                            }
                        }
                        else {
                            last_control_press = now;
                        }
                    }
                    else {
                        last_control_press = 0;
                    }
                }
            }
        }

        if fetched_clipboard_at {
            if now - fetched_clipboard_at > clipboard_fetch_timeout {
                fetched_clipboard_at = 0;
            }
            else {
                clipboard_text := os_clipboard_get_text();
                if clipboard_text != clipboard_sentinel {
                    corrected := "Replaced";
                    translated := translate_to_keystroke_string(corrected);
                    generate_keystrokes(translated);
                    generate_keystrokes("cVc");
                    fetched_clipboard_at = 0;
                }
                if clipboard_text free(clipboard_text);
            }
        }

        Simp.clear_render_target(color.x, color.y, color.z, color.w);

        y := window_height;
        y -= (font_height + 2);
        Simp.prepare_text(font, text);
        Simp.draw_prepared_text(font, 0, y, .{1,1,1,1});

        Simp.swap_buffers(window);

        reset_temporary_storage();
        if !did_something && !should_quit
            sleep_milliseconds(1);
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
    return builder_to_string(*builder, __temporary_allocator);
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
WORD :: u16;
WCHAR :: u16;

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
CoTaskMemFree :: (microsoft_is_not_good: *void) #foreign Ole32;

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

user32 :: #foreign_system_library "user32";
kernel32 :: #foreign_system_library "kernel32";
Ole32 :: #foreign_system_library "Ole32";

REFCLSID :: *IID;
WH_KEYBOARD :: 2;
WH_KEYBOARD_LL :: 13;
COINIT_MULTITHREADED :: 0;

test_spellcheck :: () -> failed: bool {
    hr := CoInitializeEx(null, COINIT_MULTITHREADED);
    if (hr < 0) {
        print("CoInitializeEx failed: 0x%\n", cast(*void)hr);
        return true;
    }
    defer CoUninitialize();

    factory: *ISpellCheckerFactory;
    hr = CoCreateInstance(*CLSID_SpellCheckerFactory, null, CLSCTX_INPROC_SERVER, *IID_ISpellCheckerFactory, cast(**void)*factory);
    if (hr < 0) {
        print("CoCreateInstance failed: 0x%\n", cast(*void)hr);
        return true;
    }
    print("factory = %\n", factory);
    defer SpellCheckerFactory_Release(factory);


    // Check if en-US is supported
    supported := false;
    hr = SpellCheckerFactory_IsSupported(factory, utf8_to_wide("en-US"), *supported);
    if (hr < 0 || !supported) {
        print("en-US not supported: 0x%\n", cast(*void)hr);
        return true;
    }
    print("supported = %\n", supported);

    // List supported languages
    languages: *IEnumString;
    hr = SpellCheckerFactory_GetSupportedLanguages(factory, *languages);
    if (hr < 0) {
        print("GetSupportedLanguages failed: 0x%\n", cast(*void)hr);
        return true;
    }
    print("languages = %\n", languages);

    if languages {
        while true {
            language: *WCHAR;
            sf: u32;
            hr = languages.vtbl.Next(languages, 1, *language, *sf);
            if (hr == S_OK && sf == 1) {
                print("Language: %\n", language);
                CoTaskMemFree(language);
            } else {
                break;
            }
        }
    }

    // Create spell checker
    checker: *ISpellChecker;
    hr = SpellCheckerFactory_CreateSpellChecker(factory, utf8_to_wide("en-US"), *checker);
    if (hr < 0) {
        print("CreateSpellChecker failed: 0x%\n", cast(*void)hr);
        return true;
    }
    print("checker = %\n", checker);

    // Check sample text "usa" (should suggest "USA", "use", etc.)
    text := utf8_to_wide("usa");
    errors: *IEnumSpellingError;
    hr = SpellChecker_Check(checker, text, *errors);
    if (hr < 0) {
        print("Check failed: 0x%\n", cast(*void)hr);
        return true;
    }
    print("errors = %\n", errors);

    // Enumerate errors and get suggestions
    while true {
        error: *ISpellingError;
        fetched: u32;
        hr = errors.vtbl.Next(errors, 1, *error, *fetched);
        if (hr == S_OK && fetched == 1) {
            // Get error position (basic; extend for full ISpellingError vtable)
            start, len: u64;
            // Assume vtable calls: error->lpVtbl->get_StartIndex(error, &start);
            // error->lpVtbl->get_Length(error, &len);

            // Get suggestions
            word := cast(*WCHAR)(text + start);  // Simplified
            suggestions: *IEnumString;
            SpellChecker_Suggest(checker, word, *suggestions);  // Note: Re-query checker if released
            if (suggestions) {
                while true {
                    sug: *WCHAR;
                    sf: u32;
                    hr = suggestions.vtbl.Next(suggestions, 1, *sug, *sf);
                    if (hr == S_OK && sf == 1) {
                        print("Suggestion: %\n", sug);
                        CoTaskMemFree(sug);
                    } else {
                        break;
                    }
                }
                suggestions.vtbl.Release(xx suggestions);
            }

            error.vtbl.Release(xx error);  // Assuming IUnknown
        } else {
            break;
        }
    }
    errors.vtbl.Release(xx errors);

    CoUninitialize();
    print("Spell check complete.\n");
    return false;
}