// https://learn.microsoft.com/en-us/windows/win32/intl/about-the-spell-checker-api

current_language: string;
supported_languages: [] string; // Will be populated in init, with user preferred languages at the start.
user_preferred_language_count := 0; // Number of languages at the start of supported_languages that are preferred by the user.


get_supported_languages :: () -> [] string, error: string {
    if !spell_checker_factory {
        error := init();
        if error  return .[], error;
    }

    languages: *IEnumString;
    hr := SpellCheckerFactory_GetSupportedLanguages(spell_checker_factory, *languages);
    if hr != S_OK || languages == null
        return .[], tprint("GetSupportedLanguages failed: 0x%\n", cast(*void)hr);

    result: [..] string;

    while true {
        language: *WCHAR;
        sf: u32;
        hr = languages.vtbl.Next(languages, 1, *language, *sf);
        if (hr == S_OK && sf == 1) {
            array_add(*result, wide_to_utf8_new(language));
            CoTaskMemFree(language);
        } else {
            break;
        }
    }

    return result, "";
}


get_users_preferred_languages :: () -> [] string, error: string {
    // Returns the user's preferred languages, or the system default if they have none.
    // If you call with an allocator that requires freeing then you'll need to free both the array *and* the individual strings.

    MUI_LANGUAGE_NAME :: 0;
    language_count: u64;
    buffer_size : u64 = 0;
    success := GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, *language_count, null, *buffer_size);
    if !success  return .[], "Initial call to GetUserPreferredUILanguages failed.";

    if language_count == 0 {
        buffer := NewArray(LOCALE_NAME_MAX_LENGTH, WCHAR, initialized=false);
        buffer_size := GetUserDefaultLocaleName(buffer.data, LOCALE_NAME_MAX_LENGTH);
        if buffer_size == 0
            return .[], "Call to GetUserDefaultLocaleName failed.";

        language := wide_to_utf8_new(buffer.data, buffer_size - 1);
        array_free(buffer);
        result := NewArray(1, string, initialized=false);
        result[0] = language;
        return result, "";
    }

    result := NewArray(cast(s64) language_count, string, initialized=false);
    buffer := NewArray(cast(s64) buffer_size, WCHAR, initialized=false);
    success = GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, *language_count, buffer.data, *buffer_size);
    if !success
        return .[], "Final call to GetUserPreferredUILanguages failed.";

    buffer_view : [] WCHAR = ---;
    buffer_view.data = buffer.data;
    buffer_view.count = buffer.count - 1;
    language_index : u64 = 0;
    start_char_index := 0;

    for char, index: buffer_view {
        if char == 0 {
            result[language_index] = wide_to_utf8_new(*buffer_view[start_char_index], cast(s32)(index - start_char_index));
            language_index += 1;
            start_char_index = index + 1;
        }
    }

    array_free(buffer);

    return result, ifx language_index != language_count then "Error processing language names returned by GetUserPreferredUILanguages; counts do not match!";
}

#scope_file

init_factory :: () -> error: string {


    return "";
}

#scope_export

init :: (preferred_language := "") -> error: string {
    if !spell_checker_factory {
        hr := CoInitializeEx(null, COINIT_MULTITHREADED);
        if hr != S_OK
            return tprint("CoInitializeEx failed: 0x%\n", cast(*void)hr);
    }
    else {
        SpellCheckerFactory_Release(spell_checker_factory);
        spell_checker_factory = null;
    }

    hr := CoCreateInstance(*CLSID_SpellCheckerFactory, null, CLSCTX_INPROC_SERVER, *IID_ISpellCheckerFactory, cast(**void)*spell_checker_factory);
    if hr != S_OK {
        CoUninitialize();
        return tprint("CoCreateInstance failed: 0x%\n", cast(*void)hr);
    }

    if !supported_languages {
        system_supported_languages := get_supported_languages();
        user_languages := get_users_preferred_languages(,,temp);
        supported_languages = NewArray(system_supported_languages.count, string, initialized=false);
        already_inserted := NewArray(system_supported_languages.count, bool,, temp);
        add_at_index := 0;

        for user_language: user_languages {
            for supported_language, supported_language_index: system_supported_languages {
                if user_language == supported_language {
                    supported_languages[add_at_index] = supported_language;
                    already_inserted[supported_language_index] = true;
                    add_at_index += 1;
                }
            }
        }

        user_preferred_language_count = add_at_index;

        for supported_language, supported_language_index: system_supported_languages {
            if !already_inserted[supported_language_index] {
                supported_languages[add_at_index] = supported_language;
                add_at_index += 1;
            }
        }

        if supported_languages.count == 0
            return "SpellChecker reports it has no supported languages";
    }

    supported := false;
    language_wide: *u16;
    if preferred_language {
        language_wide = utf8_to_wide_new(preferred_language,, temp);
        hr = SpellCheckerFactory_IsSupported(spell_checker_factory, language_wide, *supported);
        if hr != S_OK  supported = false;
    }

    if supported {
        current_language = preferred_language;
    }
    else {
        language_wide = utf8_to_wide_new(supported_languages[0],, temp);
        hr = SpellCheckerFactory_IsSupported(spell_checker_factory, language_wide, *supported);
        if hr != S_OK  supported = false;

        if supported
            current_language = supported_languages[0];
        else
            return "Could not find a supported language\n";
    }

    hr = SpellCheckerFactory_CreateSpellChecker(spell_checker_factory, language_wide, *spell_checker);
    if hr != S_OK
        return tprint("CreateSpellChecker failed: 0x%\n", cast(*void)hr);

    return "";
}

deinit :: () {
    if spell_checker_factory
        SpellCheckerFactory_Release(spell_checker_factory);

    CoUninitialize();
}




Spell_Check_Results :: struct {
    start_index: s32;
    length: s32;
    recommended_action: CORRECTIVE_ACTION;
    replacement_suggestions: [..] string;
}

free_spell_check_results :: (results: [] Spell_Check_Results) {
    if !results  return;
    for result: results {
        for suggestion: result.replacement_suggestions
            free(suggestion);
        array_free(result.replacement_suggestions);
    }
    array_free(results);
}

check_spelling :: (text: string, single_word_suggestions_only := false) -> results: [] Spell_Check_Results, error: string {
    text_wide := utf8_to_wide_new(text,, temp);
    spelling_errors: *IEnumSpellingError;
    hr := SpellChecker_Check(spell_checker, text_wide, *spelling_errors);
    if hr != S_OK
        return .[], tprint("Check failed: 0x%\n", cast(*void)hr);
    if spelling_errors == null
        return .[], "SpellChecker_Check returned null spelling_errors, but this should not happen!\n";

    defer spelling_errors.vtbl.Release(xx spelling_errors);

    results: [..] Spell_Check_Results;

    while true {
        spelling_error: *ISpellingError;
        hr = spelling_errors.vtbl.Next(spelling_errors, *spelling_error);
        if hr != S_OK  break;

        defer spelling_error.vtbl.Release(xx spelling_error);

        suggestions: *IEnumString;
        SpellChecker_Suggest(spell_checker, text_wide, *suggestions);
        if !suggestions
            return .[], "SpellChecker_Suggest returned null suggestions, but this should not happen!\n";

        defer suggestions.vtbl.Release(xx suggestions);

        result := array_add(*results);
        start_index: s32;
        SpellingError_get_StartIndex(spelling_error, cast(*u32) *start_index);
        result.start_index = wide_to_utf8_converted_length(text_wide, cast(s32) start_index);
        length: s32;
        SpellingError_get_Length(spelling_error, cast(*u32) *length);
        result.length = wide_to_utf8_converted_length(text_wide, cast(s32) length);
        SpellingError_get_CorrectiveAction(spelling_error, cast(*s32) *result.recommended_action);

        while true {
            suggestion: *WCHAR;
            sf: u32;
            hr = suggestions.vtbl.Next(suggestions, 1, *suggestion, *sf);
            if hr == S_OK && sf == 1 {
                s := wide_to_utf8_new(suggestion);
                CoTaskMemFree(suggestion);

                contains :: (haystack: string, needle: u8) -> bool {
                    for 0 .. haystack.count - 1
                        if haystack[it] == needle
                            return true;
                    return false;
                }

                if !(single_word_suggestions_only && contains(s, #char " "))
                    array_add(*result.replacement_suggestions, s);
            } else {
                break;
            }
        }
    }

    return results, "";
}



#scope_file


CLSID_SpellCheckerFactory :: GUID.{0x7AB36653, 0x1796, 0x484B, .[0xBD, 0xFA, 0xE7, 0x4F, 0x1D, 0xB7, 0xC1, 0xDC]};
IID_ISpellCheckerFactory :: GUID.{0x8E018A9D, 0x2415, 0x4677, .[0xBF, 0x08, 0x79, 0x4E, 0xA6, 0x1F, 0x94, 0xBB]};
IID_ISpellChecker :: GUID.{0xB6FD0B71, 0x98C5, 0x403A, .[0xBF, 0x8B, 0x80, 0xEE, 0x0C, 0x7D, 0xFC, 0xAA]};
IID_IEnumString :: GUID.{0x00000101, 0x0000, 0x0000, .[0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]};
IID_IEnumSpellingError :: GUID.{0x803E3BD4, 0x2828, 0x4410, .[0x82, 0x90, 0x41, 0x8D, 0x1D, 0x73, 0xC7, 0x62]};


IEnumString :: struct {
    vtbl: *IEnumString_VTable;
}

IEnumString_VTable :: struct {
    using base: IUnknown_VTable;
    Next:   #type (this: *IEnumString, celt: u32, rgelt: **u16, pceltFetched: *u32) -> HRESULT #c_call;
    Skip:   #type (this: *IEnumString, celt: u32) -> HRESULT #c_call;
    Reset:  #type (this: *IEnumString) -> HRESULT #c_call;
    Clone:  #type (this: *IEnumString, ppenum: **IEnumString) -> HRESULT #c_call;
}


ISpellingError :: struct {
    vtbl: *ISpellingError_VTable;
}

ISpellingError_VTable :: struct {
    using base: IUnknown_VTable;
    get_StartIndex:       #type (this: *ISpellingError, startIndex: *u32) -> HRESULT #c_call;
    get_Length:           #type (this: *ISpellingError, length: *u32) -> HRESULT #c_call;
    get_CorrectiveAction: #type (this: *ISpellingError, action: *s32) -> HRESULT #c_call;
    get_Replacement:      #type (this: *ISpellingError, replacement: *BSTR) -> HRESULT #c_call;
}

CORRECTIVE_ACTION :: enum s32 {
  NONE ::            0;
  GET_SUGGESTIONS :: 1;
  REPLACE ::         2;
  DELETE ::          3;
}


IEnumSpellingError :: struct {
    vtbl: *IEnumSpellingError_VTable;
}

IEnumSpellingError_VTable :: struct {
    using base: IUnknown_VTable;
    Next: #type (this: *IEnumSpellingError, value: **ISpellingError) -> HRESULT #c_call;
}


ISpellCheckerFactory :: struct {
    vtbl: *ISpellCheckerFactory_VTable;
}

ISpellCheckerFactory_VTable :: struct {
    using base: IUnknown_VTable;
    get_SupportedLanguages: #type (this: *ISpellCheckerFactory, ppLanguages: **IEnumString) -> HRESULT #c_call;
    IsSupported: #type (this: *ISpellCheckerFactory, languageTag: LPCWSTR, isSupported: *bool) -> HRESULT #c_call;
    CreateSpellChecker: #type (this: *ISpellCheckerFactory, languageTag: LPCWSTR, spellChecker: **ISpellChecker) -> HRESULT #c_call;
}


ISpellChecker :: struct {
    vtbl: *ISpellChecker_VTable;
}

ISpellChecker_VTable :: struct {
    using base: IUnknown_VTable;
    get_LanguageTag: #type (this: *ISpellChecker, value: *LPWSTR) -> HRESULT #c_call;
    Check: #type (this: *ISpellChecker, text: LPCWSTR, value: **IEnumSpellingError) -> HRESULT #c_call;
    Suggest: #type (this: *ISpellChecker, word: LPCWSTR, value: **IEnumString) -> HRESULT #c_call;
    Add: #type (this: *ISpellChecker, word: LPCWSTR) -> HRESULT #c_call;
    Ignore: #type (this: *ISpellChecker, word: LPCWSTR) -> HRESULT #c_call;
    AutoCorrect: #type (this: *ISpellChecker, from: LPCWSTR, to: LPCWSTR) -> HRESULT #c_call;
    GetOptionValue: #type (this: *ISpellChecker, optionId: LPCWSTR, value: *u8) -> HRESULT #c_call;
    get_OptionIds: #type (this: *ISpellChecker, value: **IEnumString) -> HRESULT #c_call;
    get_Id: #type (this: *ISpellChecker, value: *LPWSTR) -> HRESULT #c_call;
    get_LocalizedName: #type (this: *ISpellChecker, value: *LPWSTR) -> HRESULT #c_call;
    add_SpellCheckerChanged: #type (this: *ISpellChecker, handler: *ISpellCheckerChangedEventHandler, eventCookie: *DWORD) -> HRESULT #c_call;
    remove_SpellCheckerChanged: #type (this: *ISpellChecker, eventCookie: DWORD) -> HRESULT #c_call;
    GetOptionDescription: #type (this: *ISpellChecker, optionId: LPCWSTR, value: **IOptionDescription) -> HRESULT #c_call;
    ComprehensiveCheck: #type (this: *ISpellChecker, text: LPCWSTR, value: **IEnumSpellingError) -> HRESULT #c_call;
}


ISpellCheckerChangedEventHandler :: void;
IOptionDescription :: void;
LPWSTR :: *u16;
BSTR :: *u16;


SpellCheckerFactory_QueryInterface :: /*inline*/ (factory: *ISpellCheckerFactory, riid: REFIID, ppv: **void) -> HRESULT {
    return factory.vtbl.QueryInterface(xx factory, riid, ppv);
}

SpellCheckerFactory_AddRef :: /*inline*/ (factory: *ISpellCheckerFactory) -> u32 {
    return factory.vtbl.AddRef(xx factory);
}

SpellCheckerFactory_Release :: /*inline*/ (factory: *ISpellCheckerFactory) -> u32 {
    return factory.vtbl.Release(xx factory);
}

SpellCheckerFactory_GetSupportedLanguages :: /*inline*/ (factory: *ISpellCheckerFactory, ppLanguages: **IEnumString) -> HRESULT {
    return factory.vtbl.get_SupportedLanguages(xx factory, ppLanguages);
}

SpellCheckerFactory_IsSupported :: /*inline*/ (factory: *ISpellCheckerFactory, lang: LPCWSTR, pSupported: *bool) -> HRESULT {
    return factory.vtbl.IsSupported(xx factory, lang, pSupported);
}

SpellCheckerFactory_CreateSpellChecker :: /*inline*/ (factory: *ISpellCheckerFactory, lang: LPCWSTR, ppChecker: **ISpellChecker) -> HRESULT {
    return factory.vtbl.CreateSpellChecker(xx factory, lang, ppChecker);
}


SpellChecker_QueryInterface :: /*inline*/ (spell_checker: *ISpellChecker, riid: REFIID, ppv: **void) -> HRESULT {
    return spell_checker.vtbl.QueryInterface(xx spell_checker, riid, ppv);
}

SpellChecker_AddRef :: /*inline*/ (spell_checker: *ISpellChecker) -> u32 {
    return spell_checker.vtbl.AddRef(xx spell_checker);
}

SpellChecker_Release :: /*inline*/ (spell_checker: *ISpellChecker) -> u32 {
    return spell_checker.vtbl.Release(xx spell_checker);
}

SpellChecker_get_LanguageTag :: /*inline*/ (spell_checker: *ISpellChecker, value: *LPWSTR) -> HRESULT {
    return spell_checker.vtbl.get_LanguageTag(xx spell_checker, value);
}

SpellChecker_Check :: /*inline*/ (spell_checker: *ISpellChecker, text: LPCWSTR, value: **IEnumSpellingError) -> HRESULT {
    return spell_checker.vtbl.Check(xx spell_checker, text, value);
}

SpellChecker_Suggest :: /*inline*/ (spell_checker: *ISpellChecker, word: LPCWSTR, value: **IEnumString) -> HRESULT {
    return spell_checker.vtbl.Suggest(xx spell_checker, word, value);
}

SpellChecker_Add :: /*inline*/ (spell_checker: *ISpellChecker, word: LPCWSTR) -> HRESULT {
    return spell_checker.vtbl.Add(xx spell_checker, word);
}

SpellChecker_Ignore :: /*inline*/ (spell_checker: *ISpellChecker, word: LPCWSTR) -> HRESULT {
    return spell_checker.vtbl.Ignore(xx spell_checker, word);
}

SpellChecker_AutoCorrect :: /*inline*/ (spell_checker: *ISpellChecker, from: LPCWSTR, to: LPCWSTR) -> HRESULT {
    return spell_checker.vtbl.AutoCorrect(xx spell_checker, from, to);
}

SpellChecker_GetOptionValue :: /*inline*/ (spell_checker: *ISpellChecker, optionId: LPCWSTR, value: *u8) -> HRESULT {
    return spell_checker.vtbl.GetOptionValue(xx spell_checker, optionId, value);
}

SpellChecker_get_OptionIds :: /*inline*/ (spell_checker: *ISpellChecker, value: **IEnumString) -> HRESULT {
    return spell_checker.vtbl.get_OptionIds(xx spell_checker, value);
}

SpellChecker_get_Id :: /*inline*/ (spell_checker: *ISpellChecker, value: *LPWSTR) -> HRESULT {
    return spell_checker.vtbl.get_Id(xx spell_checker, value);
}

SpellChecker_get_LocalizedName :: /*inline*/ (spell_checker: *ISpellChecker, value: *LPWSTR) -> HRESULT {
    return spell_checker.vtbl.get_LocalizedName(xx spell_checker, value);
}

SpellChecker_add_SpellCheckerChanged :: /*inline*/ (spell_checker: *ISpellChecker, handler: *ISpellCheckerChangedEventHandler, eventCookie: *DWORD) -> HRESULT {
    return spell_checker.vtbl.add_SpellCheckerChanged(xx spell_checker, handler, eventCookie);
}

SpellChecker_remove_SpellCheckerChanged :: /*inline*/ (spell_checker: *ISpellChecker, eventCookie: DWORD) -> HRESULT {
    return spell_checker.vtbl.remove_SpellCheckerChanged(xx spell_checker, eventCookie);
}

SpellChecker_GetOptionDescription :: /*inline*/ (spell_checker: *ISpellChecker, optionId: LPCWSTR, value: **IOptionDescription) -> HRESULT {
    return spell_checker.vtbl.GetOptionDescription(xx spell_checker, optionId, value);
}

SpellChecker_ComprehensiveCheck :: /*inline*/ (spell_checker: *ISpellChecker, text: LPCWSTR, value: **IEnumSpellingError) -> HRESULT {
    return spell_checker.vtbl.ComprehensiveCheck(xx spell_checker, text, value);
}


SpellingError_get_StartIndex :: /*inline*/ (spelling_error: *ISpellingError, startIndex: *u32) -> HRESULT {
    return spelling_error.vtbl.get_StartIndex(spelling_error, startIndex);
}

SpellingError_get_Length :: /*inline*/ (spelling_error: *ISpellingError, length: *u32) -> HRESULT {
    return spelling_error.vtbl.get_Length(spelling_error, length);
}

SpellingError_get_CorrectiveAction :: /*inline*/ (spelling_error: *ISpellingError, action: *s32) -> HRESULT {
    return spelling_error.vtbl.get_CorrectiveAction(spelling_error, action);
}

SpellingError_get_Replacement :: /*inline*/ (spelling_error: *ISpellingError, replacement: *BSTR) -> HRESULT {
    return spelling_error.vtbl.get_Replacement(spelling_error, replacement);
}


spell_checker: *ISpellChecker;
spell_checker_factory: *ISpellCheckerFactory;


test_spellcheck :: () -> failed: bool {
    hr := CoInitializeEx(null, COINIT_MULTITHREADED);
    if hr != S_OK {
        print("CoInitializeEx failed: 0x%\n", cast(*void)hr);
        return true;
    }
    defer CoUninitialize();

    factory: *ISpellCheckerFactory;
    hr = CoCreateInstance(*CLSID_SpellCheckerFactory, null, CLSCTX_INPROC_SERVER, *IID_ISpellCheckerFactory, cast(**void)*factory);
    if hr != S_OK {
        print("CoCreateInstance failed: 0x%\n", cast(*void)hr);
        return true;
    }
    print("factory = %\n", factory);
    defer SpellCheckerFactory_Release(factory);


    // Check if en-US is supported
    supported := false;
    hr = SpellCheckerFactory_IsSupported(factory, utf8_to_wide_new("en-US"), *supported);
    if (hr < 0 || !supported) {
        print("en-US not supported: 0x%\n", cast(*void)hr);
        return true;
    }
    print("supported = %\n", supported);

    /*
    // List supported languages
    languages: *IEnumString;
    hr = SpellCheckerFactory_GetSupportedLanguages(factory, *languages);
    if hr != S_OK {
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
                print("Language: %\n", wide_to_utf8_new(language));
                CoTaskMemFree(language);
            } else {
                break;
            }
        }
    }
    */

    // Create spell checker
    checker: *ISpellChecker;
    hr = SpellCheckerFactory_CreateSpellChecker(factory, utf8_to_wide_new("en-US"), *checker);
    if (hr != S_OK) {
        print("CreateSpellChecker failed: 0x%\n", cast(*void)hr);
        return true;
    }
    print("checker = %\n", checker);

    // Check sample text "usa" (should suggest "USA", "use", etc.)
    text := utf8_to_wide_new("usa");
    errors: *IEnumSpellingError;
    hr = SpellChecker_Check(checker, text, *errors);
    if hr != S_OK {
        print("Check failed: 0x%\n", cast(*void)hr);
        return true;
    }
    print("errors = %\n", errors);

    // Enumerate errors and get suggestions
    while true {
        error: *ISpellingError;
        hr = errors.vtbl.Next(errors, *error);
        if hr == S_OK {
            suggestions: *IEnumString;
            SpellChecker_Suggest(checker, text, *suggestions);  // Note: Re-query checker if released
            if (suggestions) {
                while true {
                    suggestion: *WCHAR;
                    sf: u32;
                    hr = suggestions.vtbl.Next(suggestions, 1, *suggestion, *sf);
                    if (hr == S_OK && sf == 1) {
                        print("Suggestion: %\n", wide_to_utf8_new(suggestion));
                        CoTaskMemFree(suggestion);
                    } else {
                        break;
                    }
                }
                suggestions.vtbl.Release(xx suggestions);
            }
            error.vtbl.Release(xx error);
        } else {
            break;
        }
    }
    errors.vtbl.Release(xx errors);

    print("Spell check complete.\n");
    return false;
}


wide_to_utf8_converted_length :: (wide_string: *WCHAR, index: s32) -> s32 {
    return WideCharToMultiByte(CP_UTF8, 0, wide_string, index, null, 0, null, null);
}

Ole32 :: #system_library "Ole32";
CoUninitialize :: () -> void    #foreign Ole32;
CoInitializeEx :: (pvReserved: *void, dwCoInit: DWORD) -> HRESULT #foreign Ole32;
CoCreateInstance :: (rclsid: REFCLSID, pUnkOuter: *IUnknown, dwClsContext: CLSCTX, riid: REFIID, ppv: **void) -> HRESULT #foreign Ole32;
CoTaskMemFree :: (ptr: *void) #foreign Ole32;
GetUserPreferredUILanguages :: (dwFlags: DWORD, pulNumLanguages: *u64,  pwszLanguagesBuffer: *WCHAR,  pcchLanguagesBuffer: *u64) -> BOOL #foreign kernel32;
GetUserDefaultLocaleName :: (lpLocaleName: *WCHAR, cchLocaleName: s32) -> s32 #foreign kernel32;
COINIT_MULTITHREADED :: 0;
REFCLSID :: *IID;
WCHAR :: u16;
LANGID :: u16;
LOCALE_NAME_MAX_LENGTH :: 85;

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


#import "Basic";
#import "Windows";
#import "Windows_Utf8";
