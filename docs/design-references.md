# Design References

This doc is a lightweight moodboard for keeping AI Usage Monitor's UI consistent while we iterate on theming and macOS-native polish.

## Principles

- Prefer macOS system materials, separators, and typography; let the OS do most of the work.
- Use semantic tokens (track/border/controlFill/shadow) so themes can be swapped without rewriting views.
- Keep gradients subtle (barely-there atmosphere), avoid wallpaper-like backgrounds.
- Menubar icon: keep the current "label + meter" readability first; theme only the chrome (label/border/empty bars), not the service brand colors.

## References (Verified Links)

- Ice (menu bar manager): https://github.com/jordanbaird/Ice
  - Borrow: calm monochrome chrome, disciplined spacing, and "utility" UI that still feels native.
- Maccy (clipboard manager): https://github.com/p0deje/Maccy
  - Borrow: unobtrusive UI defaults, sensible typography hierarchy, and predictable focus/selection styling.

## References (Search Targets)

These are intentionally listed as search targets (not links) so we avoid stale/incorrect URLs.

- Stats (menu bar system monitor)
  - Search: `exelban stats macOS GitHub`
  - Borrow: compact information density and consistent micro-layouts.
- OnlySwitch (menu bar toggles)
  - Search: `OnlySwitch macOS menu bar GitHub`
  - Borrow: toggle affordances and quick-actions layout.
- ParetoSecurity (security checks)
  - Search: `ParetoSecurity macOS GitHub`
  - Borrow: settings organization and "status with explanation" patterns.
- FineTune (menu bar / utility UI)
  - Search: `FineTune macOS menu bar GitHub`
  - Borrow: premium card surfaces and restrained contrast.
- Viewfinder (menu bar / utility UI)
  - Search: `Viewfinder macOS menu bar GitHub`
  - Borrow: visual rhythm and deliberate typography.

## Internal Notes

- Theme tokens live in `Sources/AIUsageMonitor/Models/Theme.swift`.
- Theme picker gallery lives in `Sources/AIUsageMonitor/Views/ContentView.swift`.
- Menubar chrome colors are controlled by `AppTheme.menuBar` and used in `Sources/AIUsageMonitor/AIUsageMonitorApp.swift`.
