# Fhenix Desk: UI/UX audit

Audited on 2026-10-11 against commit `6993937`. Nothing in the app was changed; this file is the only output.

**How to use it:** tick `[x]` on each recommendation you approve. You can edit its **Change** text first; that text is what gets applied. Then run:

```
/goal Apply only the recommendations checked [x] in UX_AUDIT.md, exactly as written there. Leave the unchecked ones untouched. Done when the transcript lists each checked ID with the diff that applied it, and `swift build` and `swift test` both exit 0. Or stop after 30 turns.
```

**Severity**

| Level | Meaning |
|---|---|
| Blocker | Some users cannot do a core task at all (fails a WCAG Level A rule on a core flow). |
| Major | Misleads or slows every user on a core flow, or fails WCAG AA there. |
| Minor | Friction or inconsistency that has a workaround. |
| Suggestion | Polish. |

**Effort:** S is under an hour, M is half a day, L is a day or more.

## Recommendations

### Blocker

- [ ] **R1 · Blocker · Up Next, Pull Requests, Reviews, Jira** — Lists can't be used from the keyboard. A row is selected only by a mouse tap (`onTapGesture`). Rows can't take focus, so there is no arrow-key navigation, no Return to open and no focus ring. The only keyboard-driven list in the app is ⌘K search. **Change:** Build the list screens on `List(selection:)`, which gives arrow keys, type-select, a focus ring and VoiceOver row semantics for free, and keep `ListRow`'s look through `.listRowBackground` and `.listRowSeparator`. If `List` can't hold the custom rows, add `.focusable()`, `.onMoveCommand` (up and down move the selection) and `.onKeyPress(.return)` (open) to each list's `ScrollView`, and draw a focus ring on the selected row. **Where:** Sources/FhenixDesk/Views/Theme.swift:162-183, Sources/FhenixDesk/Views/PullRequestsTab.swift:41-55, Sources/FhenixDesk/Views/Reviews/ReviewsTab.swift:44-58, Sources/FhenixDesk/Views/TicketsTab.swift:29-41, Sources/FhenixDesk/Views/UpNextTab.swift:46-66. **Why:** WCAG 2.1.1 Keyboard, Level A ([w3.org](https://www.w3.org/WAI/WCAG22/Understanding/keyboard.html)); HIG lists and tables ([apple](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)). **Effort:** L

- [ ] **R2 · Blocker · Whole app** — The app exposes no accessibility semantics: `Sources/FhenixDesk` has no `.accessibility*` modifier. With VoiceOver:
  - Rows you can tap read as plain text.
  - Icon-only buttons read their SF Symbol names ("sidebar.trailing", "terminal.fill", "ellipsis.circle").
  - Status dots are silent.
  - A selected sidebar item, pill or row is not announced as selected.

  **Change:**
  - `ListRow`: add `.accessibilityElement(children: .combine)` and `.accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)`.
  - `SidebarItem` and `PillTabs`: add `.accessibilityAddTraits(.isSelected)` when chosen.
  - Icon-only controls: add `.accessibilityLabel` to `InspectorToggle` ("Details panel"), `ClaudeSessionButton` ("Attach session" / "Start session"), `PlanButton` ("Start in…"), the Reviews ellipsis menu ("More"), the search clear button ("Clear search"), `ChecksBadge` ("Checks passed / failed / running"), `StatusDot` (its meaning) and `SourceDots` ("GitHub synced / failed").
  - `BoxedStepper`: replace `Stepper("")` with a real label plus `.labelsHidden()`.

  **Where:** Sources/FhenixDesk/Views/Theme.swift:79-86, 101-121, 162-183, 254-273, 435-458; Sources/FhenixDesk/Views/Components.swift:44-63, 259-302; Sources/FhenixDesk/Views/TicketsTab.swift:246-263; Sources/FhenixDesk/Views/Reviews/ReviewsTab.swift:267-278; Sources/FhenixDesk/Views/SettingsView.swift:271; Sources/FhenixDesk/Views/DeskWindow.swift:153-167. **Why:** WCAG 4.1.2 Name, Role, Value, Level A ([w3.org](https://www.w3.org/WAI/WCAG22/Understanding/name-role-value.html)); HIG Accessibility ([apple](https://developer.apple.com/design/human-interface-guidelines/accessibility)). **Effort:** M

### Major

- [ ] **R3 · Major · Up Next, sidebar, menu panel** — The same destination shows a different number depending on where you look:

  | Where | Pull requests | Reviews | Up Next |
  |---|---|---|---|
  | Up Next tiles | "3 My open PRs" | "6 Reviews on you" | |
  | Sidebar badges | 1 | 14 | 6 (the list below it has 7 rows) |
  | Menu panel | 1 | 14 | links to "All 7 in Up Next…" |

  **Change:**
  - Use one count, with one label, for each destination everywhere.
  - Where two numbers are really needed, show both with words, for example "1 needs you · 3 open".
  - Make the Up Next badge count the rows Up Next lists, or label it "6 urgent".

  **Where:** Sources/FhenixDesk/Views/DeskWindow.swift:116-123, Sources/FhenixDesk/Views/UpNextTab.swift:71-78, Sources/FhenixDesk/Views/MenuPanelView.swift:14-20, 71-72, Sources/FhenixDesk/AppModel.swift:73. **Why:** NN/g heuristic #4 Consistency and standards ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); a dashboard should read at a glance ([nngroup](https://www.nngroup.com/articles/dashboards-preattentive/)). **Effort:** S

- [ ] **R4 · Major · Whole app** — Some text is below the contrast minimum:
  - Text styled `.tertiary` (white at 25% on the `#1B1B1B` background) is about 2.3:1. It is used for ages, "opened 3d", the stack arrow and the plan sheet's footnote.
  - The Save button puts white on `Theme.accent`, about 3.7:1.

  **Change:**
  - Use `.secondary` (about 6:1) wherever `.tertiary` styles text.
  - Darken `Theme.accent` for filled buttons to about `rgb(0.16, 0.42, 0.85)`, which gives ≥ 4.5:1 with white, or use the system `.borderedProminent` style.

  **Where:** Sources/FhenixDesk/Views/UpNextTab.swift:118, Sources/FhenixDesk/Views/PullRequestsTab.swift:102, 124, Sources/FhenixDesk/Views/TicketsTab.swift:369, Sources/FhenixDesk/Views/Theme.swift:14, Sources/FhenixDesk/Views/SettingsView.swift:160-163. **Why:** WCAG 1.4.3 Contrast (Minimum), AA ([w3.org](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)). **Effort:** S

- [ ] **R5 · Major · Pill tabs, search boxes, menu boxes, tiles** — Control edges and the selected state are nearly invisible:
  - The fills `Theme.raised` (white 0.165) and `Theme.selected` (white 0.205), and the border `Theme.line` (white 0.2), sit at 1.2–1.4:1 against the background (white 0.105).
  - A selected pill differs from the others only by that fill; the text is identical. In the screenshots, "Sprint" vs "Backlog" and "All" vs "On me" are hard to tell apart.

  **Change:**
  - Selected pill: primary text plus an accent-tinted fill (`Theme.accent.opacity(0.25)`) or a 2pt accent underline.
  - Unselected pill: `.secondary` text.
  - Raise the border of inputs and menu boxes to at least white 0.42 (about 3.2:1).

  **Where:** Sources/FhenixDesk/Views/Theme.swift:7-14, 101-121, 254-273, 313-330; Sources/FhenixDesk/Views/UpNextTab.swift:89-90. **Why:** WCAG 1.4.11 Non-text Contrast, AA ([w3.org](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html)); Gestalt similarity ([nngroup](https://www.nngroup.com/articles/gestalt-similarity/)). **Effort:** S

- [ ] **R6 · Major · Pull Requests, Reviews** — Clicking a row's title opens GitHub instead of selecting the row. The title is the biggest target in the row, so the most natural click is the one that sends you to the browser. **Change:** Make the title plain `Text`, so a click anywhere on the row selects it. GitHub stays reachable by double-click, ⌘↩ and the details panel's "Open on GitHub". **Where:** Sources/FhenixDesk/Views/PullRequestsTab.swift:109-111, Sources/FhenixDesk/Views/Reviews/ReviewsTab.swift:211-213. **Why:** NN/g heuristic #3 User control and freedom ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); Jakob's law, since a click selects a row in Mail and Finder ([lawsofux](https://lawsofux.com/jakobs-law/)). **Effort:** S

- [ ] **R7 · Major · Pull Requests** — "Approved" means two things in one row. The green chip is GitHub's review decision; the orange chip on the right is the flow stage "waiting for you to merge". Both are visible on cofhe#1084. **Change:** Rename the flow stage `.approved` to "Ready to merge", so each word keeps one meaning. **Where:** Sources/DeskCore/Model/Flow.swift:18, Sources/FhenixDesk/Views/Components.swift:35-42, 73. **Why:** NN/g heuristic #4 Consistency ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); Gestalt similarity, where the same label should mean the same thing ([nngroup](https://www.nngroup.com/articles/gestalt-similarity/)). **Effort:** S

- [ ] **R8 · Major · Up Next, Reviews, flow panel** — Disabled buttons don't say why:
  - Up Next's Review and Merge buttons explain nothing.
  - The flow's Approve explains only in a tooltip.
  - Reviews' Review explains only in a tooltip.

  **Change:**
  - When a primary button is disabled, show the reason next to it as a secondary caption ("2 reviews running", "Conflicts with main", "Review skill missing").
  - At minimum, give every disabled state a `.help(reason)`.

  **Where:** Sources/FhenixDesk/Views/UpNextTab.swift:134-136, 169-171; Sources/FhenixDesk/Views/FlowViews.swift:81-83; Sources/FhenixDesk/Views/Reviews/ReviewsTab.swift:255-258. **Why:** NN/g heuristics #1 Visibility of system status and #9 Help users recognize errors ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); tooltips must not hold vital information ([nngroup](https://www.nngroup.com/articles/tooltip-guidelines/)). **Effort:** S

- [ ] **R9 · Major · Pull Requests, Reviews, Jira** — Empty and error states are bare:
  - A GitHub error replaces the list with the raw error string, and there is no Retry.
  - On Pull Requests, a search that matches nothing leaves a blank list with no "No match" (Jira and Reviews have one).
  - The Jira error is a one-line red string in the filter bar.

  **Change:**
  - Turn `EmptyText` into an `EmptyState` that shows an icon, one sentence on what happened and one action ("Retry", "Clear search", "Open Settings → GitHub").
  - Add the missing no-match case.
  - On a failed sync, keep the last good rows visible with an "Out of date: <reason>" banner instead of blanking the list.

  **Where:** Sources/FhenixDesk/Views/Components.swift:170-176, Sources/FhenixDesk/Views/PullRequestsTab.swift:38-40, 75-82, Sources/FhenixDesk/Views/Reviews/ReviewsTab.swift:41-43, Sources/FhenixDesk/Views/TicketsTab.swift:89-91. **Why:** Empty states ([nngroup](https://www.nngroup.com/articles/empty-state-interface-design/)); error-message guidelines ([nngroup](https://www.nngroup.com/articles/error-message-guidelines/)). **Effort:** M

- [ ] **R10 · Major · Whole app** — Several states are shown by color alone:
  - Source dots (green, red, grey).
  - Nudge severity dots (red, orange, blue).
  - Search's CI dot and ticket status dots.
  - The session terminal icon's tint (green running, accent finished, red failed).

  **Change:** Pair each color with a shape or a word:
  - Distinct SF Symbols (`checkmark.circle.fill`, `xmark.circle.fill`, `clock.fill`) for CI in search, as `ChecksBadge` already does.
  - An `exclamationmark` symbol for urgent nudges.
  - The word "failed" after a failed source's name.
  - The ticket status text in rows.

  **Where:** Sources/FhenixDesk/Views/Components.swift:44-50, 97-107, 292-296; Sources/FhenixDesk/Views/DeskWindow.swift:153-167; Sources/FhenixDesk/Views/FinderView.swift:122, 139-143; Sources/FhenixDesk/Views/TicketsTab.swift:108. **Why:** WCAG 1.4.1 Use of Color, Level A ([w3.org](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html)). **Effort:** S

- [ ] **R11 · Major · Up Next, menu panel** — Priority signals contradict each other:
  - "Waiting on you" is listed first, and it is the one item that needs your press (merge cofhe#1084).
  - Yet it gets a blue "info" dot and is not counted in the badge, while routine "Review waits" rows get orange.
  - The menu panel sorts by severity, so that merge never makes its top four.

  **Change:**
  - Give `.flowWaiting` nudges `.warning` severity, so they are orange, counted and in the panel.
  - Order the panel's top items by the same groups as Up Next.

  **Where:** Sources/DeskCore/Nudges/NudgeEngine.swift:130, Sources/FhenixDesk/Views/MenuPanelView.swift:53-56, Sources/FhenixDesk/Views/UpNextTab.swift:10-23. **Why:** A dashboard highlights what needs action ([nngroup](https://www.nngroup.com/articles/dashboards-preattentive/)); NN/g heuristic #4 Consistency ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)). **Effort:** S

- [ ] **R12 · Major · Up Next, Pull Requests, Reviews** — Ages are hard to read:
  - Values like "161.4d", "261.1d" and "3.5h".
  - Up Next rows show two ages with no labels: one in the detail line, one on the right.

  **Change:**
  - Format ages without decimals in coarse units: "45m", "3h", "2d", "3w", "5mo".
  - Label the second age ("opened 3w").
  - Show the absolute date in a `.help` tooltip.

  **Where:** Sources/DeskCore/Model/TimeText.swift:5-12, Sources/FhenixDesk/Views/UpNextTab.swift:117-119, Sources/FhenixDesk/Views/PullRequestsTab.swift:122-125. **Why:** Microcopy should be scannable ([nngroup](https://www.nngroup.com/articles/ui-copy/)); Miller's law on chunking ([lawsofux](https://lawsofux.com/millers-law/)). **Effort:** S

- [ ] **R13 · Major · Whole app** — Only two keyboard shortcuts exist, ⌘K and ⌘,. There's no way to switch screens, sync, or focus a screen's search from the keyboard, and no View menu that lists the commands. **Change:** Add a "View" `CommandMenu`:

  | Command | Shortcut |
  |---|---|
  | Up Next | ⌘1 |
  | Pull Requests | ⌘2 |
  | Reviews | ⌘3 |
  | Jira | ⌘4 |
  | Sync Now | ⌘R |
  | Find | ⌘F (focuses the screen's `SearchBox`) |
  | Show/Hide Details | ⌥⌘I |

  **Where:** Sources/FhenixDesk/FhenixDeskApp.swift:25-41. **Why:** NN/g heuristic #7 Flexibility and efficiency of use ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); accelerators ([nngroup](https://www.nngroup.com/articles/ui-accelerators/)); HIG Keyboards ([apple](https://developer.apple.com/design/human-interface-guidelines/keyboards)). **Effort:** S

- [ ] **R14 · Major · Settings** — Unsaved changes are easy to lose:
  - Edits wait for Save, but Back or Esc leaves without a warning.
  - Nothing outside the page footer shows unsaved changes.
  - Nothing confirms a save.

  Most macOS settings apply as soon as you change them. **Change:**
  - Preferred: apply each change immediately and remove the Save/Revert bar.
  - If the draft model stays: show a dot on "Back to Desk" and on the pane names that hold edits, ask "Save changes?" on Back/Esc when the draft has unsaved edits, and show "Saved" for 2 s after Save.

  **Where:** Sources/FhenixDesk/Views/SettingsView.swift:87-102, 133-180. **Why:** HIG Settings ([apple](https://developer.apple.com/design/human-interface-guidelines/settings)); NN/g heuristics #1 and #5 Error prevention ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)). **Effort:** M

- [ ] **R15 · Major · Settings → Jira, Reviews, GitHub** — Several values must be typed exactly as free text:
  - Jira status names, "exactly as Jira spells them, emoji and all".
  - The model and effort.
  - Project keys, repo roots and bot logins, as comma-separated text. In the screenshot, the Bot logins field already cuts off its own list ("claude, github-actions, dependabot,").

  **Change:**
  - Status fields: pickers filled from Jira's workflow statuses through `acli jira`.
  - Model and effort: pickers of the known values.
  - Repo roots: a folder picker (`fileImporter`).
  - Comma lists: one token per entry.
  - On Save, validate and show an inline error under the field.

  **Where:** Sources/FhenixDesk/Views/SettingsView.swift:325-328, 352-360, 387-388. **Why:** NN/g heuristic #5 Error prevention ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); WCAG 3.3.2 Labels or Instructions ([w3.org](https://www.w3.org/WAI/WCAG22/Understanding/labels-or-instructions.html)). **Effort:** L

- [ ] **R16 · Major · ⌘K Search** — Search finds only PRs and screen names. Jira tickets aren't searchable even though Jira is a top-level screen, and there are no commands such as Sync, Review #123 or a Settings pane. **Change:**
  - Add tickets (matched by key and summary; ↩ opens them on Jira).
  - Add commands (Sync now, Settings panes, Review/Attach on the matched PR), each showing its shortcut.
  - Rank matches loosely, not by plain substring.

  **Where:** Sources/FhenixDesk/Views/FinderView.swift:14-32, 100-108. **Why:** A command palette exposes every action ([superhuman](https://blog.superhuman.com/how-to-build-a-remarkable-command-palette/)); Jakob's law ([lawsofux](https://lawsofux.com/jakobs-law/)). **Effort:** M

### Minor

- [ ] **R17 · Minor · Reviews** — Reviews has no details panel, unlike Pull Requests and Jira. Its rows grow to three lines to make up for it, so only about eight fit on screen. **Change:** Add `.deskInspector("reviews")` holding the PR's status, review draft, checks and the worktree actions now in the ellipsis menu, and cut the row to two lines. **Where:** Sources/FhenixDesk/Views/Reviews/ReviewsTab.swift:33-72, 171-198, 245-280. **Why:** NN/g heuristic #4 Consistency ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); detail belongs in a side panel ([nngroup](https://www.nngroup.com/articles/data-tables/)). **Effort:** M

- [ ] **R18 · Minor · Reviews, Up Next** — One state has three names and repeats on every row:
  - All 14 rows carry an orange "ready to review" chip.
  - The header says "14 ready to run".
  - Up Next says "Review waits:".

  **Change:**
  - Show the readiness chip only for the exceptions ("review again", "run failed").
  - Use one term everywhere, for example "Needs review".
  - Show the header chip only when it differs from the row count.

  **Where:** Sources/FhenixDesk/Views/Reviews/ReviewsTab.swift:100-103, 232-235; Sources/DeskCore/Reviews/ReviewReadiness.swift:12-17; Sources/DeskCore/Nudges/NudgeEngine.swift:82. **Why:** Use badges sparingly ([nngroup](https://www.nngroup.com/articles/indicators-validations-notifications/)); identical wording everywhere ([nngroup](https://www.nngroup.com/articles/ui-copy/)). **Effort:** S

- [ ] **R19 · Minor · Up Next** — The rows are hard to scan:
  - Six identical blue "Review" buttons compete for attention.
  - Every row title starts "Review waits:", under a header that already says "Review".
  - The PR's real title sits on the dim second line.

  **Change:**
  - Lead each row with the PR title, and put `repo#number`, author and age on the meta line.
  - Keep `.borderedProminent` for the first row's action only; the rest use `.bordered`.

  **Where:** Sources/FhenixDesk/Views/UpNextTab.swift:108-121, 134-136; Sources/DeskCore/Nudges/NudgeEngine.swift:82. **Why:** Visual hierarchy, with one focal point ([nngroup](https://www.nngroup.com/articles/visual-hierarchy-ux-definition/)); Hick's law ([lawsofux](https://lawsofux.com/hicks-law/)). **Effort:** S

- [ ] **R20 · Minor · Pull Requests** — Titles don't line up. Status chips of different widths ("Not required Clean", "Approved Clean", "Draft Blocked") sit before each title, so every title starts at a different x. **Change:** Move `PullRequestStatus` after the title, or into a fixed-width column on the right, so all titles share one leading edge. **Where:** Sources/FhenixDesk/Views/PullRequestsTab.swift:106-113. **Why:** Shared leading edges ([apple](https://developer.apple.com/design/human-interface-guidelines/layout)); the readable identifier comes first ([nngroup](https://www.nngroup.com/articles/data-tables/)). **Effort:** S

- [ ] **R21 · Minor · Pull Requests** — Some row elements carry nothing:
  - The avatar is always yours, since this list holds only your PRs.
  - The checkbox looks like bulk selection but is a private mark that is lost when the app quits.
  - A "–" stands for "no ticket" and for "not in a flow".

  **Change:**
  - Drop the avatar on this screen.
  - Drop the checkbox, or persist it and give it a visible meaning ("Mark as seen").
  - Leave empty values out instead of drawing "–".

  **Where:** Sources/FhenixDesk/Views/PullRequestsTab.swift:99-105, 157-173, 185; Sources/FhenixDesk/Views/FlowViews.swift:247. **Why:** NN/g heuristic #8 Aesthetic and minimalist design ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); Jakob's law, since a checkbox in a list means selection ([lawsofux](https://lawsofux.com/jakobs-law/)). **Effort:** S

- [ ] **R22 · Minor · Pull Requests, Jira** — The details panel opens empty and takes a quarter of the width ("Select a pull request."). **Change:** Select the first row when the screen appears and nothing is selected. **Where:** Sources/FhenixDesk/Views/PullRequestsTab.swift:63-70, Sources/FhenixDesk/Views/TicketsTab.swift:45-52. **Why:** NN/g heuristic #8 Minimalist design ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)). **Effort:** S

- [ ] **R23 · Minor · Whole app** — Nothing reacts to hovering (rows, pills, tiles, sidebar items, menu-panel items), and right-clicking does nothing anywhere. **Change:**
  - Add a hover fill (`.onHover` sets `Theme.raised`) to `ListRow`, `PillTabs`, `SidebarItem`, the tiles and the panel's nudge rows.
  - Add `.contextMenu` to rows: Open on GitHub, Copy link, Copy branch, Review/Attach.

  **Where:** Sources/FhenixDesk/Views/Theme.swift:101-121, 162-183, 435-458; Sources/FhenixDesk/Views/UpNextTab.swift:80-94; Sources/FhenixDesk/Views/MenuPanelView.swift:57-69. **Why:** Rows get a hover highlight ([nngroup](https://www.nngroup.com/articles/data-tables/)); Jakob's law, since macOS has context menus everywhere ([lawsofux](https://lawsofux.com/jakobs-law/)). **Effort:** M

- [ ] **R24 · Minor · Up Next, menu panel** — The big numbers behave inconsistently:
  - Up Next's tiles open their screen but don't look clickable.
  - The menu panel's counters look the same and do nothing.

  **Change:**
  - Give the tiles a hover state and a trailing `chevron.right`.
  - Make the panel counters buttons that open their screen.

  **Where:** Sources/FhenixDesk/Views/UpNextTab.swift:71-94, Sources/FhenixDesk/Views/MenuPanelView.swift:40-49. **Why:** NN/g heuristic #4 Consistency ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)). **Effort:** S

- [ ] **R25 · Minor · Menu bar item** — A click opens the window and a right-click opens the panel, but nothing tells you the panel exists. Most menu bar extras open their panel or menu on click. **Change:** Set a tooltip on the status item ("Click: open Desk · Right-click: quick look"), or swap the two clicks to match the convention. **Where:** Sources/FhenixDesk/FhenixDeskApp.swift:114-126, 182-189. **Why:** HIG The menu bar ([apple](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)); Jakob's law ([lawsofux](https://lawsofux.com/jakobs-law/)). **Effort:** S

- [ ] **R26 · Minor · Whole app** — The app ignores the system appearance. The window, the menu panel and the plan sheet force dark, so captures taken in light mode are byte-identical to the dark ones. The theme is built from hard-coded grays, so Increase Contrast has no effect either. **Change:**
  - Move `Theme` to dynamic colors with light, dark and high-contrast variants (an asset catalog or `NSColor(name:dynamicProvider:)`).
  - Then remove `.preferredColorScheme(.dark)` and `.darkAqua`.

  **Where:** Sources/FhenixDesk/Views/Theme.swift:6-20, Sources/FhenixDesk/Views/DeskWindow.swift:61, Sources/FhenixDesk/Views/MenuPanelView.swift:28, Sources/FhenixDesk/FhenixDeskApp.swift:147, Sources/FhenixDesk/Views/TicketsTab.swift:385. **Why:** HIG Dark Mode says not to offer an app-only appearance and to test with Increase Contrast ([apple](https://developer.apple.com/design/human-interface-guidelines/dark-mode)); HIG Color ([apple](https://developer.apple.com/design/human-interface-guidelines/color)). **Effort:** L

- [ ] **R27 · Minor · Settings** — The form's wording gets in the way:
  - Instructions live in placeholders ("empty = auto", "comma separated"), which disappear as soon as you type.
  - Labels read awkwardly ("GitHub, every", "Reviews at once, at most").
  - Intervals show as seconds ("300 s").

  **Change:**
  - Move format hints into a caption under each field.
  - Use noun labels ("GitHub poll interval", "Parallel reviews", "Budget per run").
  - Show durations of 60 s or more in minutes.

  **Where:** Sources/FhenixDesk/Views/SettingsView.swift:283-291, 313, 325-328, 362, 382, 387-398. **Why:** WCAG 3.3.2 Labels or Instructions ([w3.org](https://www.w3.org/WAI/WCAG22/Understanding/labels-or-instructions.html)); UI copy ([nngroup](https://www.nngroup.com/articles/ui-copy/)). **Effort:** S

- [ ] **R28 · Minor · Settings** — A failed save shows Swift's raw error text (`"\(error)"`). **Change:** Show a plain sentence that says what failed and what to do ("Couldn't save settings: <reason>. Check that ~/Library/Application Support/Fhenix Desk is writable."), with the raw error in a `.help` tooltip. **Where:** Sources/FhenixDesk/AppModel.swift:177, Sources/FhenixDesk/Views/SettingsView.swift:138-139. **Why:** Error-message guidelines ([nngroup](https://www.nngroup.com/articles/error-message-guidelines/)). **Effort:** S

- [ ] **R29 · Minor · Pull Requests details** — "Copy branch" gives no feedback. **Change:** Change the label to "Copied" for 1.5 s after the press. **Where:** Sources/FhenixDesk/Views/PullRequestsTab.swift:221-224. **Why:** NN/g heuristic #1 Visibility of system status ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); Doherty threshold ([lawsofux](https://lawsofux.com/doherty-threshold/)). **Effort:** S

- [ ] **R30 · Minor · Whole app** — Wording and capitalization drift between screens:
  - Chips use both "Approved" and "approved", "Draft" and "draft".
  - The same screen is "Jira", "Open tickets" and "Tickets".
  - The scope pill says "On me" but the row chip says "on you".
  - Search's key hints read "open / github / close".

  **Change:**
  - Pick sentence case for chips and hints ("Approved", "Draft", "Open on GitHub").
  - Use one name for the tickets screen.
  - Use "on you" in both places.

  **Where:** Sources/FhenixDesk/Views/Components.swift:70-76, 228-249; Sources/FhenixDesk/Views/Reviews/ReviewsTab.swift:210; Sources/FhenixDesk/Views/UpNextTab.swift:75; Sources/FhenixDesk/Views/FinderView.swift:77-79, 114-118. **Why:** NN/g heuristics #2 Match the real world and #4 Consistency ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); identical wording ([nngroup](https://www.nngroup.com/articles/ui-copy/)). **Effort:** S

- [ ] **R31 · Minor · Pull Requests, Reviews, Jira, Settings → Repos** — Some icons carry their meaning only in a tooltip:
  - The bare terminal icon can mean "attach", "start a session" or "start planning", depending on its fill and tint.
  - Settings → Repos shows nine identical orange warning triangles, one per tracked repo, with no text.

  **Change:**
  - Label the session buttons ("Attach", "Start session", "Start in…") at `.controlSize(.small)`, the way the details panels already do.
  - On Repos, pass `showsText: true` to `ReviewSkillMark` so the reason shows, or show the warning once above the list ("9 repos can't run the review skill: <reason>").

  **Where:** Sources/FhenixDesk/Views/Components.swift:259-302, Sources/FhenixDesk/Views/TicketsTab.swift:240-263, Sources/FhenixDesk/Views/SettingsView.swift:456-458. **Why:** Ambiguous icons need text labels ([nngroup](https://www.nngroup.com/articles/icon-usability/)). **Effort:** S

- [ ] **R32 · Minor · ⌘K Search** — Two small problems with search results:
  - Every PR result carries a green "open" chip, though all of them are open.
  - "No PR or page matches." is a dead end.

  **Change:**
  - Show the chip only for drafts.
  - On no match, offer "Search GitHub for “<query>”" on ⌘↩.

  **Where:** Sources/FhenixDesk/Views/FinderView.swift:54-58, 117-118. **Why:** NN/g heuristic #8 Minimalist design ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)); empty states should offer an action ([nngroup](https://www.nngroup.com/articles/empty-state-interface-design/)). **Effort:** S

- [ ] **R33 · Minor · Window** — The window has no minimum size, so in a small window the 640 pt search panel, the 212 pt sidebar and the 260 pt minimum details panel can clip. **Change:** Add `.frame(minWidth: 960, minHeight: 560)` to `DeskRoot` and `.windowResizability(.contentMinSize)` to the scene. **Where:** Sources/FhenixDesk/FhenixDeskApp.swift:18-24, Sources/FhenixDesk/Views/FinderView.swift:85. **Why:** HIG Layout ([apple](https://developer.apple.com/design/human-interface-guidelines/layout)). **Effort:** S

- [ ] **R34 · Minor · Menu panel, search boxes** — Some click targets are small: the panel's "Quit" is caption-size plain text, and the search clear button is an icon of about 14 pt. **Change:** Give both a hit area of at least 24×24 pt with `.frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())`. **Where:** Sources/FhenixDesk/Views/MenuPanelView.swift:86, Sources/FhenixDesk/Views/Theme.swift:263-266. **Why:** WCAG 2.5.8 Target Size (Minimum), AA ([w3.org](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)); Fitts's law ([lawsofux](https://lawsofux.com/fittss-law/)). **Effort:** S

- [ ] **R35 · Minor · Settings → Jira, Repos, Prompts** — Four visual details mislead on the Settings screenshots:
  - Jira's read-only "Site" and "Signed in as" are drawn in the same boxes as editable fields, so they look editable.
  - The neutral account note ("The Atlassian CLI holds the credentials…") is green, the color of success.
  - "Clear", which untracks every repo, sits directly beside the harmless "Reload".
  - The Prompts picker is inset from the page's left edge.

  **Change:**
  - Show read-only values as plain secondary text with no `InputBox`.
  - Make the note `.secondary`; keep a green checkmark only on "Signed in".
  - Move "Clear" away from "Reload" and rename it "Untrack all".
  - Give the picker `.frame(maxWidth: 320, alignment: .leading)`.

  **Where:** Sources/FhenixDesk/Views/SettingsView.swift:343-347, 432-436, 516-517. **Why:** Signifiers and Gestalt similarity, where things that look alike should act alike ([nngroup](https://www.nngroup.com/articles/gestalt-similarity/)); proximity, keeping unrelated actions apart ([nngroup](https://www.nngroup.com/articles/gestalt-proximity/)); shared leading edges ([apple](https://developer.apple.com/design/human-interface-guidelines/layout)). **Effort:** S

### Suggestion

- [ ] **R36 · Suggestion · Typography** — The app uses about ten text sizes (9, 10, 11, 12, 13, 15, 22 and 24 pt, plus the 11.5 pt code font, all scaled by 1.08). Guidance is at most three per view, and the 9 pt key caps sit at macOS's 10 pt minimum. **Change:** Reduce to five roles: title 22, headline 15, body 14, secondary 12, caption 11. Drop `footnote` and map the key caps to caption. **Where:** Sources/FhenixDesk/Views/AppFont.swift:21-34, Sources/FhenixDesk/Views/Theme.swift:46. **Why:** Visual hierarchy ([nngroup](https://www.nngroup.com/articles/visual-hierarchy-ux-definition/)); HIG Typography ([apple](https://developer.apple.com/design/human-interface-guidelines/typography)). **Effort:** M

- [ ] **R37 · Suggestion · Spacing** — Off-scale spacing values (1, 3, 5, 6, 9, 10, 14, 18 and 22 pt) mix with the 4/8 grid. **Change:** Add spacing tokens to `Theme` (`xs 4, s 8, m 12, l 16, xl 24, xxl 32`) and use them for padding and stack spacing. **Where:** Sources/FhenixDesk/Views/Theme.swift:17-19, 153-154, 338-339, 389-390, 430; Sources/FhenixDesk/Views/Components.swift:12-13. **Why:** Carbon spacing scale ([carbon](https://carbondesignsystem.com/elements/spacing/overview/)); Atlassian spacing tokens ([atlassian](https://atlassian.design/foundations/spacing)). **Effort:** M

- [ ] **R38 · Suggestion · Text size** — Text is fixed at 1.08× macOS's sizes, and you can't make it larger. **Change:** Add a "Text size" setting (Small 1.0, Default 1.08, Large 1.2) that feeds `AppTextStyle.scale`, which then needs to come from the environment instead of a `static let`. **Where:** Sources/FhenixDesk/Views/AppFont.swift:15, Sources/FhenixDesk/Views/SettingsView.swift:277-303. **Why:** HIG Accessibility, larger text ([apple](https://developer.apple.com/design/human-interface-guidelines/accessibility)). **Effort:** M

- [ ] **R39 · Suggestion · Motion** — Scrolling to the selected row animates even with Reduce Motion on. **Change:** Read `@Environment(\.accessibilityReduceMotion)` and skip `withAnimation` when it is on. **Where:** Sources/FhenixDesk/Views/PullRequestsTab.swift:53, Sources/FhenixDesk/Views/Reviews/ReviewsTab.swift:56. **Why:** WCAG 2.3.3 Animation from Interactions ([w3.org](https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions.html)). **Effort:** S

- [ ] **R40 · Suggestion · Settings** — Settings replaces the whole window, main sidebar included, where macOS apps usually open a separate Settings window. **Change:** Keep it in the window, but leave the main sidebar visible with Settings selected, so you never lose your place. Or move it to a SwiftUI `Settings` scene. **Where:** Sources/FhenixDesk/Views/DeskWindow.swift:38-48, Sources/FhenixDesk/Views/SettingsView.swift:83-119. **Why:** HIG Settings ([apple](https://developer.apple.com/design/human-interface-guidelines/settings)); Jakob's law ([lawsofux](https://lawsofux.com/jakobs-law/)). **Effort:** M

- [ ] **R41 · Suggestion · Sidebar, Settings** — Some chrome is redundant:
  - The single "Workspace" heading sits over the only group.
  - The key-hint strip at the foot of Settings repeats shortcuts already shown on the Save and Back buttons.

  **Change:** Remove both. **Where:** Sources/FhenixDesk/Views/DeskWindow.swift:77, Sources/FhenixDesk/Views/SettingsView.swift:113. **Why:** NN/g heuristic #8 Minimalist design ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)). **Effort:** S

- [ ] **R42 · Suggestion · Up Next** — The "all clear" state is a single grey line. **Change:** Use the `EmptyState` from R9 with a checkmark icon, "All clear · synced 2m ago" and a "Browse the review queue" button. **Where:** Sources/FhenixDesk/Views/UpNextTab.swift:61-63. **Why:** Empty states ([nngroup](https://www.nngroup.com/articles/empty-state-interface-design/)). **Effort:** S

- [ ] **R43 · Suggestion · Notifications** — Clicking a notification opens GitHub in the browser, while the same nudge in Up Next has Desk's buttons (Review, Merge, Attach). **Change:** Open the item in Desk on its screen with the row selected, and add an "Open on GitHub" notification action. **Where:** Sources/FhenixDesk/Notifier.swift:48-52. **Why:** NN/g heuristic #4 Consistency ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)). **Effort:** M

## Screens reviewed

Every screen was read in its SwiftUI source. Screenshots come from the running app: the dev build via `make run` / `swift run FhenixDesk`, then a scratch copy outside the repo with launch hooks to open Settings, search and the panel. They are saved in `/tmp/fhenix-ux`.

For light mode the app was launched with `-AppleInterfaceStyle Light`. Each light capture is the same image as its dark one (R26).

| Screen | Source | Screenshots (dark / light) |
|---|---|---|
| Menu bar panel | MenuPanelView.swift, FhenixDeskApp.swift | dark-panel-layer25.png / light-panel-layer25.png |
| Up Next (was Today) | UpNextTab.swift | dark-upnext.png / light-upnext.png |
| Pull Requests | PullRequestsTab.swift, Components.swift, FlowViews.swift | dark-pullrequests-main.png / light-pullrequests-main.png |
| Reviews | Reviews/ReviewsTab.swift | dark-reviews-main.png / light-reviews-main.png |
| Jira (with details panel) | TicketsTab.swift, MarkdownText.swift | dark-jira-main.png / light-jira-main.png |
| ⌘K Search: empty, matching, no match | FinderView.swift | dark-finder-{empty,query,nomatch}-main.png / light-… |
| Settings: General, GitHub, Repos, Jira, Reviews, Prompts | SettingsView.swift | dark-settings-{general,github,repos,jira,reviews,prompts}-main.png / light-… (captured after you allowed unsandboxed screen capture) |
| Shared chrome: sidebar, sync row, theme, fonts | DeskWindow.swift, Theme.swift, AppFont.swift | visible in every capture |

## Research checklist

Each finding above was checked against this list. Every URL was fetched and resolved during the audit.

1. **NN/g 10 usability heuristics** ([nngroup](https://www.nngroup.com/articles/ten-usability-heuristics/)):
   - Every action gives immediate feedback, and sync state is always visible.
   - The same word, icon or color means the same thing everywhere.
   - High-cost errors are prevented first.
   - Recognition over recall.
   - Accelerators exist for frequent actions.
   - Each view shows only what serves its goal.
   - Errors are plain and specific, and offer a fix.
2. **Laws of UX:**
   - Fitts: frequent targets are large and close ([lawsofux](https://lawsofux.com/fittss-law/)).
   - Hick: fewer choices where speed matters, with one recommended option ([lawsofux](https://lawsofux.com/hicks-law/)).
   - Jakob: reuse familiar patterns, such as a Mail-like sidebar and list and a ⌘K palette ([lawsofux](https://lawsofux.com/jakobs-law/)).
   - Miller: chunk long lists into labeled groups ([lawsofux](https://lawsofux.com/millers-law/)).
   - Doherty: respond within 400 ms, and show progress for anything longer ([lawsofux](https://lawsofux.com/doherty-threshold/)).
   - Aesthetic-usability: polish hides problems, so measure task success ([lawsofux](https://lawsofux.com/aesthetic-usability-effect/)).
3. **Gestalt and hierarchy:**
   - Spacing inside a group is smaller than spacing between groups ([proximity](https://www.nngroup.com/articles/gestalt-proximity/)).
   - Boxes only where whitespace can't group ([common region](https://www.nngroup.com/articles/common-region/)).
   - The same look means the same behavior ([similarity](https://www.nngroup.com/articles/gestalt-similarity/)).
   - At most three type sizes and one or two focal points per view ([hierarchy](https://www.nngroup.com/articles/visual-hierarchy-ux-definition/)).
   - Shared leading edges ([HIG layout](https://developer.apple.com/design/human-interface-guidelines/layout)).
4. **WCAG 2.2:**
   - 1.4.3: text ≥ 4.5:1 ([1.4.3](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)).
   - 1.4.11: control edges and states ≥ 3:1 ([1.4.11](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html)).
   - 1.4.1: never color alone ([1.4.1](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html)).
   - 2.1.1: everything works from the keyboard ([2.1.1](https://www.w3.org/WAI/WCAG22/Understanding/keyboard.html)).
   - 2.4.7 and 2.4.11: focus is visible and not hidden ([2.4.7](https://www.w3.org/WAI/WCAG22/Understanding/focus-visible.html), [2.4.11](https://www.w3.org/WAI/WCAG22/Understanding/focus-not-obscured-minimum.html)).
   - 4.1.2: every control exposes its name, role and state ([4.1.2](https://www.w3.org/WAI/WCAG22/Understanding/name-role-value.html)).
   - 2.5.8: targets ≥ 24×24 ([2.5.8](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)).
   - 2.3.3: honor Reduce Motion ([2.3.3](https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions.html)).
   - 3.3.2: every input has a label or instructions ([3.3.2](https://www.w3.org/WAI/WCAG22/Understanding/labels-or-instructions.html)).
5. **Type, spacing and color:**
   - One 4/8 spacing scale, used as tokens ([carbon](https://carbondesignsystem.com/elements/spacing/overview/), [atlassian](https://atlassian.design/foundations/spacing)).
   - Built-in text styles; macOS body is 13 pt and the minimum is 10 pt ([HIG typography](https://developer.apple.com/design/human-interface-guidelines/typography)).
   - Color tokens by role and state ([carbon color](https://carbondesignsystem.com/elements/color/tokens/)).
   - System dynamic colors with light, dark and high-contrast variants ([HIG color](https://developer.apple.com/design/human-interface-guidelines/color)).
6. **Feedback, loading, empty and error states:**
   - Under 0.1 s feels instant; past 1 s show that work is happening; past 10 s show progress and a way to cancel ([response times](https://www.nngroup.com/articles/response-times-3-important-limits/), [progress](https://www.nngroup.com/articles/progress-indicators/), [skeletons](https://www.nngroup.com/articles/skeleton-screens/)).
   - An empty state explains and offers an action ([empty states](https://www.nngroup.com/articles/empty-state-interface-design/)).
   - Nothing changes silently ([system status](https://www.nngroup.com/articles/visibility-system-status/)).
   - Errors appear next to their source, specific and with a remedy ([errors](https://www.nngroup.com/articles/error-message-guidelines/)).
   - Badges are used sparingly ([indicators](https://www.nngroup.com/articles/indicators-validations-notifications/)).
7. **Microcopy and progressive disclosure:**
   - Commands start with a verb, and wording is identical everywhere ([UI copy](https://www.nngroup.com/articles/ui-copy/), [writing](https://www.nngroup.com/articles/ux-writing-study-guide/)).
   - Confirm only what can't be undone ([confirmation](https://www.nngroup.com/articles/confirmation-dialog/)).
   - Frequent features up front, at most two levels deep ([disclosure](https://www.nngroup.com/articles/progressive-disclosure/)).
   - Tooltips never hold vital information ([tooltips](https://www.nngroup.com/articles/tooltip-guidelines/)).
   - Ambiguous icons get labels ([icons](https://www.nngroup.com/articles/icon-usability/)).
8. **Dashboards and productivity tools:**
   - One glance, highlighting what needs action ([dashboards](https://www.nngroup.com/articles/dashboards-preattentive/)).
   - Tables: readable identifier first, active filters visible, row hover, one or two inline actions, detail in a side panel ([data tables](https://www.nngroup.com/articles/data-tables/)).
   - ⌘K palette: every action is a command, with its shortcut shown ([superhuman](https://blog.superhuman.com/how-to-build-a-remarkable-command-palette/), [accelerators](https://www.nngroup.com/articles/ui-accelerators/)).
9. **macOS conventions:**
   - Menu bar extras ([menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)) and sidebars ([sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)).
   - Lists, tables and toolbars ([lists](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)).
   - Search fields: the placeholder states the scope ([search](https://developer.apple.com/design/human-interface-guidelines/search-fields)).
   - Settings: changes apply immediately ([settings](https://developer.apple.com/design/human-interface-guidelines/settings)).
   - No app-only dark mode ([dark mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)).
   - Standard shortcuts and full keyboard access ([keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)).
   - Controls about 28 pt, minimum 20 pt ([accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)).
   - Menu items in title case, with an ellipsis when more input is needed ([menus](https://developer.apple.com/design/human-interface-guidelines/menus)).
