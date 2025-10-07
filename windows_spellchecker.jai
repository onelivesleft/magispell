BSTR :: *u16;

// GUID Definitions (from Windows SDK spellcheck.h equivalents)
CLSID_SpellCheckerFactory :: GUID.{0x7AB36653, 0x1796, 0x484B, .[0xBD, 0xFA, 0xE7, 0x4F, 0x1D, 0xB7, 0xC1, 0xDC]};
IID_ISpellCheckerFactory :: GUID.{0x8E018A9D, 0x2415, 0x4677, .[0xBF, 0x08, 0x79, 0x4E, 0xA6, 0x1F, 0x94, 0xBB]};
IID_ISpellChecker :: GUID.{0xB6FD0B71, 0x98C5, 0x403A, .[0xBF, 0x8B, 0x80, 0xEE, 0x0C, 0x7D, 0xFC, 0xAA]};
IID_IEnumString :: GUID.{0x00000101, 0x0000, 0x0000, .[0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]};
IID_IEnumSpellingError :: GUID.{0x803E3BD4, 0x2828, 0x4410, .[0x82, 0x90, 0x41, 0x8D, 0x1D, 0x73, 0xC7, 0x62]};

// IUnknown base (shared)
IUnknownVtbl :: struct {
    QueryInterface: #type (This: *void, riid: REFIID, ppvObject: **void) -> HRESULT #c_call;
    AddRef: #type (This: *void) -> u64 #c_call;
    Release: #type (This: *void) -> u64 #c_call;
} ;


// IEnumString vtable
IEnumString_VTable :: struct {
    using _ : IUnknown_VTable;  // Embed IUnknown vtable
    Next:   #type (this: *IEnumString, celt: u32, rgelt: **u16, pceltFetched: *u32) -> HRESULT #c_call;
    Skip:   #type (this: *IEnumString, celt: u32) -> HRESULT #c_call;
    Reset:  #type (this: *IEnumString) -> HRESULT #c_call;
    Clone:  #type (this: *IEnumString, ppenum: **IEnumString) -> HRESULT #c_call;
}

IEnumString :: struct {
    vtbl: *IEnumString_VTable;
}

// ISpellingError vtable (minimal; extend as needed)
ISpellingError_VTable :: struct {
    using _ : IUnknown_VTable;  // Embed IUnknown
    // Key methods
    get_StartIndex:    #type (this: *ISpellingError, startIndex: *u32) -> HRESULT #c_call;
    get_Length:        #type (this: *ISpellingError, length: *u32) -> HRESULT #c_call;
    get_CorrectiveAction: #type (this: *ISpellingError, action: *s32) -> HRESULT #c_call;
    get_Replacement:   #type (this: *ISpellingError, replacement: *BSTR) -> HRESULT #c_call;
    // Add more methods from docs as needed
}

ISpellingError :: struct {
    vtbl: *ISpellingError_VTable;
}

// IEnumSpellingError vtable
IEnumSpellingError_VTable :: struct {
    using _ : IUnknown_VTable;  // Embed IUnknown
    Next:  #type (this: *IEnumSpellingError, celt: u32, rgelt: **ISpellingError, pceltFetched: *u32) -> HRESULT #c_call;
    Skip:  #type (this: *IEnumSpellingError, celt: u32) -> HRESULT #c_call;
    Reset: #type (this: *IEnumSpellingError) -> HRESULT #c_call;
    Clone: #type (this: *IEnumSpellingError, ppenum: **IEnumSpellingError) -> HRESULT #c_call;
}

IEnumSpellingError :: struct {
    vtbl: *IEnumSpellingError_VTable;
}

// ISpellCheckerFactory vtable
ISpellCheckerFactory_VTable :: struct {
    using _ : IUnknown_VTable;  // Embed IUnknown
    CreateSpellChecker: #type (this: *ISpellCheckerFactory, languageTag: LPCWSTR, spellChecker: **ISpellChecker) -> HRESULT #c_call;
    get_SupportedLanguages: #type (this: *ISpellCheckerFactory, ppLanguages: **IEnumString) -> HRESULT #c_call;
    IsSupported: #type (this: *ISpellCheckerFactory, languageTag: LPCWSTR, isSupported: *bool) -> HRESULT #c_call;
}

ISpellCheckerFactory :: struct {
    vtbl: *ISpellCheckerFactory_VTable;
}

// ISpellChecker vtable (core methods; extend with full ~15 methods as needed)
ISpellChecker_VTable :: struct {
    using _ : IUnknown_VTable;  // Embed IUnknown
    // Selected methods for basic usage
    Check: #type (this: *ISpellChecker, text: LPCWSTR, errors: **IEnumSpellingError) -> HRESULT #c_call;
    Suggest: #type (this: *ISpellChecker, text: LPCWSTR, suggestions: **IEnumString) -> HRESULT #c_call;
    get_LanguageTag: #type (this: *ISpellChecker, languageTag: *BSTR) -> HRESULT #c_call;
    // Add others like Add, Ignore, AutoCorrect, etc., following Microsoft docs
}

ISpellChecker :: struct {
    vtbl: *ISpellChecker_VTable;
}


SpellCheckerFactory_QueryInterface :: inline (factory: *ISpellCheckerFactory, riid: REFIID, ppv: **void) -> HRESULT {
    return factory.vtbl.QueryInterface(xx factory, riid, ppv);
}

SpellCheckerFactory_AddRef :: inline (factory: *ISpellCheckerFactory) -> u32 {
    return factory.vtbl.AddRef(xx factory);
}

SpellCheckerFactory_Release :: inline (factory: *ISpellCheckerFactory) -> u32 {
    return factory.vtbl.Release(xx factory);
}

SpellCheckerFactory_CreateSpellChecker :: inline (factory: *ISpellCheckerFactory, lang: LPCWSTR, ppChecker: **ISpellChecker) -> HRESULT {
    return factory.vtbl.CreateSpellChecker(xx factory, lang, ppChecker);
}

SpellCheckerFactory_GetSupportedLanguages :: inline (factory: *ISpellCheckerFactory, ppLanguages: **IEnumString) -> HRESULT {
    return factory.vtbl.get_SupportedLanguages(xx factory, ppLanguages);
}

SpellCheckerFactory_IsSupported :: inline (factory: *ISpellCheckerFactory, lang: LPCWSTR, pSupported: *bool) -> HRESULT {
    return factory.vtbl.IsSupported(xx factory, lang, pSupported);
}

SpellChecker_QueryInterface :: inline (checker: *ISpellChecker, riid: REFIID, ppv: **void) -> HRESULT {
    return checker.vtbl.QueryInterface(xx checker, riid, ppv);
}

SpellChecker_AddRef :: inline (checker: *ISpellChecker) -> u32 {
    return checker.vtbl.AddRef(xx checker);
}

SpellChecker_Release :: inline (checker: *ISpellChecker) -> u32 {
    return checker.vtbl.Release(xx checker);
}

SpellChecker_Check :: inline (checker: *ISpellChecker, text: LPCWSTR, ppErrors: **IEnumSpellingError) -> HRESULT {
    return checker.vtbl.Check(xx checker, text, ppErrors);
}

SpellChecker_Suggest :: inline (checker: *ISpellChecker, text: LPCWSTR, ppSuggestions: **IEnumString) -> HRESULT {
    return checker.vtbl.Suggest(xx checker, text, ppSuggestions);
}

SpellChecker_get_LanguageTag :: inline (checker: *ISpellChecker, pTag: *BSTR) -> HRESULT {
    return checker.vtbl.get_LanguageTag(xx checker, pTag);
}
