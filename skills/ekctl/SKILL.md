---
name: ekctl
description: Manage local Apple Calendar events and calendars and Apple Reminders with the ekctl CLI. Use when the user explicitly mentions ekctl or asks to operate on Apple Calendar, macOS Calendar, Apple Reminders, or the Mac's local EventKit data. Do not use for Google or Outlook calendars, Codex reminders or scheduled automations, or writing EventKit application code.
---

# ekctl

Use the local `ekctl` binary to read or change Apple Calendar and Reminders data through EventKit. Do not substitute another calendar/reminder tool when the user selected `ekctl`.

## Establish the installed interface

- Run `command -v ekctl` and `ekctl --version` before the first operation in a task. If the binary is absent, stop and report that; do not install or upgrade it unless the user asks.
- Treat `ekctl help <command> [<subcommand>]` as authoritative for the installed version. Inspect it before using an advanced or unfamiliar flag.
- Do not use flags merely because upstream documentation mentions them. For example, use `--time-format` only when the installed command's help advertises it.

## Choose the command

| Intent | Command |
|---|---|
| Discover aliases | `ekctl alias list` |
| Discover event calendars and reminder lists | `ekctl list calendars` |
| Today's or tomorrow's events | `ekctl today` / `ekctl tomorrow` |
| Next upcoming events | `ekctl next` |
| Events in a custom range or matching filters | `ekctl list events` |
| Reminders in a list, optionally filtered | `ekctl list reminders` |
| Inspect one item | `ekctl show event` / `ekctl show reminder` |
| Create an item | `ekctl add event` / `ekctl add reminder` |
| Change an item | `ekctl update event` / `ekctl update reminder` |
| Mark a reminder urgent (rings as an alarm at its due time) | `ekctl update reminder ID --urgent true` / `ekctl add reminder ... --urgent true` |
| Complete a reminder | `ekctl complete reminder` |
| Delete an item | `ekctl delete event` / `ekctl delete reminder` |
| Manage friendly names | `ekctl alias set|remove|list` |
| Create, change, or delete an event calendar | `ekctl calendar create|update|delete` |

JSON is the authoritative format for agent processing. When the user requests CSV or text, first run the read in JSON and verify success, then repeat the same read with `--format csv` or `--format text`. Keep mutations in JSON so their result can be verified.

## Resolve targets

- Prefer an existing alias. Check `ekctl alias list` before enumerating the EventKit stores when the user supplied a friendly calendar or list name.
- If no alias or ID resolves the target, use `ekctl list calendars` and match both title and `type`; event commands require an event calendar and reminder commands require a reminder list. Require `allowsModifications: true` for writes.
- `ekctl` 1.4 requests both Calendar and Reminders access when `list calendars` runs, so use that broader discovery command only when needed.
- Events may be read from multiple comma-separated calendars. Reminder reads accept one list per call; repeat read-only queries when the user asks across several lists.
- Never invent or truncate an item ID. Resolve it from current JSON output. If multiple targets still match, show the candidates and ask the user to choose before mutating anything.

## Resolve dates and times

- Read the current local date, time, timezone, and UTC offset from the system before interpreting relative dates; do not guess them.
- Prefer `today`, `tomorrow`, and `next` for their exact built-in meanings.
- For writes and custom ranges, pass a full ISO 8601 timestamp with an explicit offset or `Z`. Preserve the user's intended timezone and verify that an event's end is after its start.
- For a one-day all-day event, use local midnight at the requested date as the start and local midnight on the following date as the end, together with `--all-day`.
- Ask only when the requested time, timezone, duration, or recurrence cannot be inferred safely.

## Execute safely

- Read-only requests authorize only read commands. Create, update, complete, alias, calendar-management, and delete commands require a corresponding explicit user request.
- Before updating, completing, or deleting an item, resolve an exact ID and inspect it with `show` unless the immediately preceding result already identifies exactly one target. Before updating or deleting a calendar, verify the exact calendar in `list calendars`.
- Pass only fields the user asked to change. `update` leaves omitted fields unchanged.
- Parse the JSON after every command and require `status: "success"`. In `ekctl` 1.4, some EventKit/domain failures can be returned as `status: "error"` even when the process exit status is zero; never infer success from the exit code alone.
- On an error, report the returned message and stop. Do not retry with a different target or broader mutation.
- After a write, use the returned object as confirmation. Re-read only when the response omits a field needed to verify the requested result.

## Preserve ekctl semantics

- Reminder priorities are `0` none, `1` high, `5` medium, and `9` low.
- Urgent is separate from priority. `--urgent true` makes a reminder ring as a full-screen alarm at its due time (macOS 26+). It requires a due date: pass `--due`, or target a reminder that already has one. ekctl adds a due-time alarm if the reminder has none. `--urgent false` turns it off. Reminder JSON reports `urgent` as `true`, `false`, or `null`, where `null` means the urgent state can't be read on this system. Older builds don't have `--urgent`, so check `ekctl help update reminder` first, and if it's missing, say the installed version can't do it.
- "Urgent" means this flag, not priority `1`. Don't substitute one for the other.
- Event alarm values are minutes relative to the start: `10` means 10 minutes before and `+10` means 10 minutes after. On event update, `--alarms` replaces all existing alarms.
- `ekctl` 1.4 updates or deletes only the selected occurrence of a recurring event. Do not claim or attempt a series-wide edit; explain that the installed CLI does not expose it.
- Calendar/Reminders permission failures require the appropriate access in System Settings > Privacy & Security. Name the specific permission that failed.
- Do not improvise unsupported operations: reminder-list creation, attendee invitations, or moving items between calendars or lists.

## Report the result

For reads, summarize the matching items in local time. For writes, report success or failure, the item title, calendar/list, relevant local date and time, and the returned ID. Keep raw JSON internal unless the user requests it.
