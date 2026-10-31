<!-- SPDX-License-Identifier: AGPL-3.0-only -->
# Russian glossary for the window's strings

The Russian localization (`app_ru.arb`) follows this glossary. The English terms come from `app_en.arb` and were checked
against the site (`site/public/index.html`). How localization is built and how to add a string: `docs/DESIGN.md`,
"Languages".

The language picker in "Settings" shows each language in its own language: **System / English / Русский**.

| en | ru | Note |
| --- | --- | --- |
| contact | связь / контакт | in the interface, the person at the other end: "New contact", "Remove contact" |
| link | связь (канал) | where the channel is meant: "Link ID", "Linked with “X”", "the link is read-only" |
| trust level 1–4: Observer · Acquaintance · Colleague · Partner | уровень доверия: Наблюдатель · Знакомый · Коллега · Партнёр | as on the site |
| trust level 5, shown as ∞ "My computer" | ∞ «Мой компьютер» | window only (D-UI-30); the number 5 stays in the CLI and the protocol; the site still says "Self" / «Свой» |
| verification code | проверочный код / код сверки | "compare the code by voice" |
| invite / invite link | приглашение / ссылка-приглашение | "burns in 09:41", "the invite burned" (сгорело) |
| approve / deny, approval request | одобрить / отклонить, запрос на одобрение | "Allow once", "Deny everything from this contact for an hour" |
| quarantine | карантин | |
| daemon | daemon | not translated |
| History verified | История сверена | the badge in the chat header; "diverged" is расхождение |
| rekey | ре-кеинг | |
| E2E · PQ | E2E · PQ | not translated |
| relay only / direct | только relay / прямой | network mode |
| owner password | пароль владельца | |
| lock keys / unlock | закрыть ключи / разблокировать | `antenna lock` / `antenna unlock` |
| data label | метка данных | of an agent |
| activity log, receipt | журнал действий, квитанция | |
| fingerprint | отпечаток | |
| Chat / Code (interface modes) | Чат / Код; режим «Код» | Settings → Interface |
| terminal (of an agent) | терминал | Code mode |
| role preset; Assistant / Front desk | роль по умолчанию; помощник / приёмная | data label 5 / 0 |
| local model; local agent | локальная модель; локальный агент | Agents → Local models (CONTROL §24) |
| Local · runs on this Mac / this computer | Локально · работает на этом Mac / этом компьютере | the badge of a local agent; «Локально» alone in the chat list |
| conversation (of a local agent); New conversation | переписка; новая переписка | not «чат» or «диалог» |
| profile picture (Your picture, Picture for <agent>); Use my photo… | аватар (Ваш аватар, Аватар для <agent>); Своё фото… | a drawn animal or a photo; not «картинка» or «фото профиля» |
| download; checking the file | скачать; проверяем файл | a model's states |
| team; lead; worker | команда; ведущий; исполнитель | Teams (CONTROL §25); the lead is «ведущий», never «лидер» |
| task; board; round | задача; доска; раунд | a task's states: Открыта, Назначена, В работе, Вопрос ведущему, Сдана, Возвращена, Принята, Применена, Отменена |
| budget; kind of worker; rules | бюджет; вид исполнителей; правила | New team |
| check (of a task); check command | проверка; команда проверки | not «тест» |
| apply (to a branch); the team's branch | применить (к ветке); ветка команды | «Применить к main» |
| turn (of an agent) | ход | a worker's turn |
