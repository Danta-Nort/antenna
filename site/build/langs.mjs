// SPDX-License-Identifier: Apache-2.0
// The languages of antenna.contact, in the order every list shows them (the owner's rule: English, Spanish,
// Portuguese, then by speakers weighted by paying ability). A language is on the site once site/i18n/<code>/strings.json
// exists; from then on every page must exist in it (build/site.mjs fails otherwise).
export const LANGS = [
  { code: 'en', hreflang: 'en', name: 'English', locale: 'en_US', dateLocale: 'en-GB' },
  { code: 'es', hreflang: 'es', name: 'Español', locale: 'es_ES', dateLocale: 'es' },
  { code: 'pt', hreflang: 'pt-BR', name: 'Português', locale: 'pt_BR', dateLocale: 'pt-BR' },
  { code: 'zh', hreflang: 'zh-Hans', name: '简体中文', locale: 'zh_CN', dateLocale: 'zh-CN' },
  { code: 'hi', hreflang: 'hi', name: 'हिन्दी', locale: 'hi_IN', dateLocale: 'hi-IN' },
  { code: 'ar', hreflang: 'ar', name: 'العربية', locale: 'ar_AR', dateLocale: 'ar-u-nu-latn', dir: 'rtl' },
  { code: 'fr', hreflang: 'fr', name: 'Français', locale: 'fr_FR', dateLocale: 'fr' },
  { code: 'de', hreflang: 'de', name: 'Deutsch', locale: 'de_DE', dateLocale: 'de' },
  { code: 'ja', hreflang: 'ja', name: '日本語', locale: 'ja_JP', dateLocale: 'ja' },
  { code: 'ko', hreflang: 'ko', name: '한국어', locale: 'ko_KR', dateLocale: 'ko' },
  { code: 'tr', hreflang: 'tr', name: 'Türkçe', locale: 'tr_TR', dateLocale: 'tr' },
  { code: 'it', hreflang: 'it', name: 'Italiano', locale: 'it_IT', dateLocale: 'it' },
  { code: 'pl', hreflang: 'pl', name: 'Polski', locale: 'pl_PL', dateLocale: 'pl' },
  { code: 'ru', hreflang: 'ru', name: 'Русский', locale: 'ru_RU', dateLocale: 'ru' },
  { code: 'uk', hreflang: 'uk', name: 'Українська', locale: 'uk_UA', dateLocale: 'uk' },
];
