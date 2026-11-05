# Dashboard and interaction polish

- Dashboard metric links open the relevant inventory/status filters.
- Count-up and staggered entry run only once per workspace identity per page load.
  Reduced-motion preferences disable count-up and all decorative motion.
- Status donut uses actual request counts; it does not invent historical trends.
- Availability bars show on-hand stock minus pending reservations. Zero stock
  avoids division by zero. Other teachers' reservations remain aggregated in Java mode.
- Inventory pages clamp after filtering/deletion; row sizes are 5, 10 or 25.
- Item details preserve the teacher's own-history restriction.
- Timelines show submission and the stored terminal timestamp. Reviewer identity
  is not invented because the original data model does not record it.
- Real API requests display progress; state reads display skeletons. Form buttons
  disable and show saving feedback, then restore on success/failure. No artificial
  network delay is introduced for demonstrations.
- Native details/summary provides keyboard-operable request timelines. Dialogs
  retain native modal focus behavior and close with Escape or the close controls.

Local validation: browser route/filter/pagination/details/timeline checks, theme
persistence and mobile overflow checks, Java-backed sign-in/save, nine Node tests.
Backend service and HTTP integration remain covered by the existing CI suite.
