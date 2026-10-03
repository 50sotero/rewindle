"use client";

import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import {
  Activity as IconActivity,
  PanelLeftClose as IconSidebarLeftArrow,
  Pencil as IconEditBig,
  Plus as IconPlusMedium,
  RotateCcw as IconRestore,
  Search as IconMagnifyingGlass,
  ChevronRight as IconChevronRight,
  Settings as IconSettingsGear1,
  ShieldCheck as IconShieldCheck,
  X as IconCrossSmall,
} from "lucide-react";
import GlideMenu from "@/components/primitives/GlideMenu";

/* ─────────────────────────────────────────────────────────
 * SIDEBAR NAV
 * Shared by the design-system preview and the harness shell:
 * the product lockup, primary navigation, searchable history,
 * and a collapse that preserves icon alignment.
 * ───────────────────────────────────────────────────────── */

/** The product's own lockup in the header: its mark and name. It is not a menu; folded, only the mark stays. */
export type SidebarBrand = {
  name: string;
  /** Drawn as given, with nothing behind it, so a mark that brings its own tile (the app's does) is not framed twice. Decoration: the name is always in the page. */
  logo: ReactNode;
};

export type SidebarNavItem = {
  key: string;
  label: string;
  icon: ReactNode;
  count?: string | number;
  /** The keyboard shortcut that opens this item, in aria-keyshortcuts form ("Control+1"); shown in its tooltip too. */
  shortcut?: string;
};

/** "Control+1" as people say it. */
const shortcutLabel = (shortcut: string) => shortcut.replace(/^Control\+/, "Ctrl+");

const DEFAULT_BRAND: SidebarBrand = {
  name: "Rewindle",
  logo: <img src="./rewindle-icon.svg" alt="" className="size-full" draggable={false} />,
};

const DEFAULT_NAV_ITEMS: SidebarNavItem[] = [
  { key: "protection", label: "Protection", icon: <IconShieldCheck size={18} /> },
  { key: "activity", label: "Activity", icon: <IconActivity size={18} /> },
  { key: "restore", label: "Restore", icon: <IconRestore size={18} /> },
  { key: "settings", label: "Settings", icon: <IconSettingsGear1 size={18} /> },
];

export type SidebarRecent = {
  id: string;
  label: string;
  prompt?: string;
};

const DEFAULT_RECENTS: SidebarRecent[] = [
  { id: "latest", label: "Latest backup" },
  { id: "weekly", label: "Weekly verification" },
  { id: "documents", label: "Documents snapshot" },
  { id: "photos", label: "Photos snapshot" },
];

export type SidebarNavProps = {
  brand?: SidebarBrand;
  navItems?: SidebarNavItem[];
  activeTitle?: string | null;
  className?: string;
  fill?: boolean;
  primaryActionLabel?: string | null;
  primaryActionIcon?: ReactNode;
  onPrimaryAction?: () => void;
  primaryActionDisabled?: boolean;
  primaryActionHelp?: string;
  onNewChat?: () => void;
  onPick?: (id: string, label: string, prompt?: string) => void;
  /** controlled primary-nav selection (e.g. "protection" | "activity") */
  activeNav?: string;
  onNavigate?: (key: string) => void;
  footerLabel?: string | null;
  footerIcon?: ReactNode;
  onFooterClick?: () => void;
  footerDisabled?: boolean;
  footerActive?: boolean;
  footerShortcut?: string;
  recents?: SidebarRecent[];
  recentLabel?: string;
  recentSearchLabel?: string;
  onViewAll?: () => void;
  viewAllLabel?: string;
  variant?: string;
  /** Where the person's own choice of folded or open is kept between launches (localStorage). Without a key it lasts as long as the page. */
  storageKey?: string;
};

// At or below this width the sidebar folds to its icon rail by itself. A high zoom does that to even a wide window (at 200% a 900 pixel
// window is about 450 CSS pixels across), and the expanded sidebar alone takes 224 of them, which left the page 176 and cut its content off.
const NARROW_QUERY = "(max-width: 700px)";
// Until the person has chosen, a window this narrow or narrower starts with the sidebar folded: at the desktop app's smallest size (about 884
// CSS pixels across) the open sidebar leaves the page about 610 of them. Choosing, either way, is kept and from then on decides.
const COMPACT_QUERY = "(max-width: 1040px)";

const mediaMatches = (query: string) => typeof window !== "undefined" && typeof window.matchMedia === "function" && window.matchMedia(query).matches;

// The stored choice is true when the person folded the sidebar and false when they opened it; null when they have not chosen, or when
// storage cannot be read (it is blocked in some profiles and windows), in which case the window's width decides.
function readStoredChoice(key: string | undefined): boolean | null {
  if (!key) return null;
  try {
    const stored = window.localStorage.getItem(key);
    return stored === "collapsed" ? true : stored === "expanded" ? false : null;
  } catch {
    return null;
  }
}

function storeChoice(key: string | undefined, collapsed: boolean) {
  if (!key) return;
  try {
    window.localStorage.setItem(key, collapsed ? "collapsed" : "expanded");
  } catch {
    /* The choice then lasts until the page is closed. */
  }
}

const SIDEBAR_MOTION = {
  expandedWidth: 224,
  collapsedWidth: 52,
  duration: 280,
  copyDuration: 180,
  copyOffset: 8,
  easing: "cubic-bezier(0.16, 1, 0.3, 1)",
};

/* ─────────────────────────────────────────────────────────
 * CHAT SEARCH STORYBOARD
 *
 *   0ms   search is triggered; Chats label begins fading
 *   0ms   field grows right → left from the search control
 * 180ms   field fills the row; cursor is focused and ready
 * ───────────────────────────────────────────────────────── */
const CHAT_SEARCH_MOTION = {
  duration: 180,
  closedWidth: 28,
  easing: "cubic-bezier(0.16, 1, 0.3, 1)",
};

function GlideGroup({ children }: { children: ReactNode }) {
  return (
    <GlideMenu
      rowSelector="[data-row]"
      highlightClassName="sidebar-glide-highlight rounded-[7px] bg-hover-2"
      className="group/glide flex flex-col gap-px"
    >
      {children}
    </GlideMenu>
  );
}

function RailButton({
  icon,
  label,
  active = false,
  count,
  onClick,
  disabled = false,
  help,
  shortcut,
}: {
  icon: ReactNode;
  label: string;
  active?: boolean;
  count?: string;
  onClick?: () => void;
  disabled?: boolean;
  help?: string;
  shortcut?: string;
}) {
  const tip = help || label;
  return (
    <button
      data-row
      type="button"
      disabled={disabled}
      aria-label={label}
      title={shortcut ? `${tip} (${shortcutLabel(shortcut)})` : tip}
      aria-description={help}
      aria-keyshortcuts={shortcut}
      aria-current={active ? 'page' : undefined}
      onClick={onClick}
      className={`sidebar-row relative z-10 mx-2 flex h-8 items-center rounded-[8px] px-2 text-left
        transition-[width,background-color,color,transform] duration-150 active:scale-[0.98] disabled:pointer-events-none disabled:opacity-50
        ${active ? "bg-accent-tint" : ""}`}
    >
      <span className={`flex size-5 shrink-0 items-center justify-center ${active ? "text-accent-ink" : "text-ink-2"}`}>
        {icon}
      </span>
      <span className={`sidebar-copy ml-1.5 min-w-0 flex-1 truncate text-[14px] font-medium ${active ? "text-ink" : "text-ink-2"}`}>
        {label}
      </span>
      {count && (
        <span className="sidebar-copy mr-2 shrink-0 text-[12px] font-medium tabular-nums text-ink-3">
          {count}
        </span>
      )}
    </button>
  );
}

export default function SidebarNav({
  brand = DEFAULT_BRAND,
  navItems = DEFAULT_NAV_ITEMS,
  activeTitle,
  className = "",
  fill = false,
  primaryActionLabel = "Run backup",
  primaryActionIcon = <IconPlusMedium size={18} />,
  onPrimaryAction,
  primaryActionDisabled = false,
  primaryActionHelp,
  onNewChat,
  onPick,
  activeNav,
  onNavigate,
  footerLabel = null,
  footerIcon,
  onFooterClick,
  footerDisabled = false,
  footerActive = false,
  footerShortcut,
  recents = DEFAULT_RECENTS,
  recentLabel = "Backup history",
  recentSearchLabel = "Search backup history",
  onViewAll,
  viewAllLabel = "View all activity",
  storageKey,
}: SidebarNavProps) {
  // The person's own choice applies while the window is wide: it is kept (when there is a storage key) and, until they have made one,
  // the window's width decides. While it is narrow the sidebar is folded unless it was opened by hand, and that goes back to folded when
  // the width next crosses the line (so zooming back out gives the person's own choice again).
  const [choice, setChoice] = useState<boolean | null>(() => readStoredChoice(storageKey));
  const [compact, setCompact] = useState(() => mediaMatches(COMPACT_QUERY));
  const wideCollapsed = choice ?? compact;
  const [narrow, setNarrow] = useState(() => mediaMatches(NARROW_QUERY));
  const [openWhileNarrow, setOpenWhileNarrow] = useState(false);
  const collapsed = narrow ? !openWhileNarrow : wideCollapsed;
  const setCollapsed = (value: boolean) => {
    if (narrow) { setOpenWhileNarrow(!value); return; }
    setChoice(value);
    storeChoice(storageKey, value);
  };
  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;
    const query = window.matchMedia(NARROW_QUERY);
    const apply = () => { setNarrow(query.matches); setOpenWhileNarrow(false); };
    apply();
    query.addEventListener("change", apply);
    return () => query.removeEventListener("change", apply);
  }, []);
  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;
    const query = window.matchMedia(COMPACT_QUERY);
    const apply = () => setCompact(query.matches);
    apply();
    query.addEventListener("change", apply);
    return () => query.removeEventListener("change", apply);
  }, []);
  const [internalNav, setInternalNav] = useState("protection");
  const currentNav = activeNav ?? internalNav;
  const selectNav = (key: string) => {
    setInternalNav(key);
    onNavigate?.(key);
  };
  const [demoActiveTitle, setDemoActiveTitle] = useState<string | null>(null);
  const [searchOpen, setSearchOpen] = useState(false);
  const [query, setQuery] = useState("");
  const searchButtonRef = useRef<HTMLButtonElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const collapseButtonRef = useRef<HTMLButtonElement>(null);
  const expandButtonRef = useRef<HTMLButtonElement>(null);
  // The toggle that takes focus once the sidebar has changed width. The one that was pressed goes inert in that same render,
  // and focus left on it would be lost, so it moves to the one that has just become the visible control.
  const focusToggleRef = useRef<"collapse" | "expand" | null>(null);

  const selectedTitle = activeTitle === undefined ? demoActiveTitle : activeTitle;
  const visibleRecents = recents.filter((item) => item.label.toLowerCase().includes(query.trim().toLowerCase()));

  useEffect(() => {
    if (searchOpen) searchRef.current?.focus();
  }, [searchOpen]);

  // A sidebar folded by the window's width does to an open search what the collapse button does.
  useEffect(() => {
    if (!collapsed) return;
    setSearchOpen(false);
    setQuery("");
  }, [collapsed]);

  // After the commit, so the toggle that is now visible is no longer inert when it is focused.
  useEffect(() => {
    const toggle = focusToggleRef.current;
    if (!toggle) return;
    focusToggleRef.current = null;
    (toggle === "expand" ? expandButtonRef : collapseButtonRef).current?.focus({ preventScroll: true });
  }, [collapsed]);

  const collapse = () => {
    focusToggleRef.current = "expand";
    setCollapsed(true);
    setSearchOpen(false);
    setQuery("");
  };

  const expand = () => {
    focusToggleRef.current = "collapse";
    setCollapsed(false);
  };

  return (
    <aside
      data-sidebar-collapsed={collapsed}
      aria-label="Sidebar"
      className={`relative flex shrink-0 overflow-hidden transition-[width] ${fill ? "h-full" : "h-[600px]"} ${className}`}
      style={{
        width: collapsed ? SIDEBAR_MOTION.collapsedWidth : SIDEBAR_MOTION.expandedWidth,
        transitionDuration: `${SIDEBAR_MOTION.duration}ms`,
        transitionTimingFunction: SIDEBAR_MOTION.easing,
        "--sidebar-copy-duration": `${SIDEBAR_MOTION.copyDuration}ms`,
        "--sidebar-copy-offset": `${SIDEBAR_MOTION.copyOffset}px`,
        "--sidebar-easing": SIDEBAR_MOTION.easing,
      } as CSSProperties}
    >
      <div className="flex min-h-0 w-[224px] shrink-0 flex-col">
        <div className="sidebar-header relative mb-2.5 h-10 shrink-0">
          {/* The product's lockup: its mark and name, not a menu. Folded, the mark stays on the rail and the expand button lies over
              it, showing its arrow in the mark's place while it is pointed at or focused. */}
          <div className="sidebar-brand absolute left-2 top-1 flex h-8 w-[164px] items-center px-2">
            <span aria-hidden="true" className="sidebar-logo flex size-5 shrink-0 items-center justify-center">{brand.logo}</span>
            <span className="sidebar-copy ml-1.5 min-w-0 flex-1 truncate text-[14px] font-semibold text-ink">{brand.name}</span>
          </div>

          {/* Whichever of the two does not apply is inert, so it is neither focusable nor read; they share one aria-expanded. */}
          <button
            ref={collapseButtonRef}
            type="button"
            aria-label="Collapse sidebar"
            aria-expanded={!collapsed}
            inert={collapsed}
            onClick={collapse}
            className="sidebar-collapse-control absolute right-2 top-1 flex size-8 items-center justify-center rounded-[8px] text-ink-3 transition-[opacity,background-color,color] duration-150 hover:bg-hover-2 hover:text-ink"
          >
            <IconSidebarLeftArrow size={18} />
          </button>
          {/* left-2.5 and size-8 keep the arrow centered on the rail glyphs (x = 26), as the old size-9 at left-2 did. */}
          <button
            ref={expandButtonRef}
            type="button"
            aria-label="Expand sidebar"
            aria-expanded={!collapsed}
            inert={!collapsed}
            onClick={expand}
            className="sidebar-expand-control absolute left-2.5 top-1 flex size-8 items-center justify-center rounded-[8px] text-ink-3 transition-[opacity,background-color,color] duration-150 hover:bg-hover-2 hover:text-ink"
          >
            <IconSidebarLeftArrow size={18} className="rotate-180" />
          </button>
        </div>

        <nav aria-label="Primary">
          <GlideGroup>
            {primaryActionLabel && <RailButton
              icon={primaryActionIcon ?? <IconEditBig size={18} />}
              label={primaryActionLabel}
              disabled={primaryActionDisabled}
              help={primaryActionHelp}
              onClick={
                primaryActionDisabled
                  ? undefined
                  : () => {
                      if (activeTitle === undefined) setDemoActiveTitle(null);
                      (onPrimaryAction ?? onNewChat)?.();
                    }
              }
            />}
            {navItems.map((item) => (
              <RailButton
                key={item.key}
                icon={item.icon}
                label={item.label}
                count={item.count?.toString()}
                shortcut={item.shortcut}
                active={currentNav === item.key}
                onClick={() => selectNav(item.key)}
              />
            ))}
          </GlideGroup>
        </nav>

        <div aria-hidden={collapsed} inert={collapsed} className={`mt-3 min-h-0 flex-1 overflow-y-auto transition-opacity duration-150 ${collapsed ? 'pointer-events-none opacity-0' : 'opacity-100'}`}>
          <div className="sidebar-copy relative mx-2 mb-1 h-8">
            <div
              aria-hidden={searchOpen}
              className={`absolute inset-0 flex items-center gap-1.5 px-2 text-[13px] font-medium text-ink-3 transition-[opacity,transform] ${searchOpen ? "pointer-events-none -translate-x-1 opacity-0" : "translate-x-0 opacity-100"}`}
              style={{ transitionDuration: `${CHAT_SEARCH_MOTION.duration}ms`, transitionTimingFunction: CHAT_SEARCH_MOTION.easing }}
            >
              <span>{recentLabel}</span>
            </div>

            <button
              ref={searchButtonRef}
              type="button"
              aria-label={recentSearchLabel}
              aria-expanded={searchOpen}
              aria-hidden={searchOpen || collapsed}
              tabIndex={searchOpen || collapsed ? -1 : 0}
              onClick={() => setSearchOpen(true)}
              className={`absolute right-0 top-0 z-10 flex size-8 items-center justify-center rounded-[8px] text-ink-3 transition-[opacity,background-color,color,transform] hover:bg-hover-2 hover:text-ink active:scale-[0.96] ${searchOpen ? "pointer-events-none opacity-0" : "opacity-100"}`}
              style={{ transitionDuration: `${CHAT_SEARCH_MOTION.duration}ms` }}
            >
              <IconMagnifyingGlass size={16} />
            </button>

            <div
              aria-hidden={!searchOpen || collapsed}
              className={`sidebar-search absolute right-0 top-0 z-20 flex h-8 items-center overflow-hidden rounded-[8px] bg-field text-ink-3 shadow-hairline transition-[width,opacity] focus-within:text-ink-2 ${searchOpen ? "pointer-events-auto opacity-100" : "pointer-events-none opacity-0"}`}
              style={{
                width: searchOpen ? "100%" : CHAT_SEARCH_MOTION.closedWidth,
                transitionDuration: `${CHAT_SEARCH_MOTION.duration}ms`,
                transitionTimingFunction: CHAT_SEARCH_MOTION.easing,
              }}
            >
              <span className="ml-2 flex shrink-0 items-center justify-center">
                <IconMagnifyingGlass size={15} />
              </span>
              <input
                ref={searchRef}
                tabIndex={searchOpen && !collapsed ? 0 : -1}
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Escape") {
                    event.preventDefault();
                    setSearchOpen(false);
                    setQuery("");
                    searchButtonRef.current?.focus();
                  }
                }}
                placeholder={recentSearchLabel}
                aria-label={recentSearchLabel}
                className="ml-1.5 min-w-0 flex-1 bg-transparent text-[13px] font-medium text-ink outline-none placeholder:text-ink-3"
              />
              <button
                type="button"
                aria-label="Close search"
                tabIndex={searchOpen && !collapsed ? 0 : -1}
                onClick={() => {
                  setSearchOpen(false);
                  setQuery("");
                  searchButtonRef.current?.focus();
                }}
                className="flex size-8 shrink-0 items-center justify-center rounded-[8px] text-ink-3 transition-[background-color,color,transform] duration-150 hover:bg-hover-2 hover:text-ink active:scale-[0.96]"
              >
                <IconCrossSmall size={16} />
              </button>
            </div>
          </div>

          <GlideGroup>
            {visibleRecents.map((item) => {
              const active = item.label === selectedTitle;
              return (
                <button
                  key={item.id}
                  data-row
                  type="button"
                  title={item.label}
                  aria-current={active ? "true" : undefined}
                  onClick={() => {
                    if (!onPick) selectNav("activity");
                    if (activeTitle === undefined) setDemoActiveTitle(item.label);
                    onPick?.(item.id, item.label, item.prompt);
                  }}
                  className={`sidebar-row relative z-10 mx-2 flex h-8 items-center rounded-[8px] px-2 text-left transition-[width,background-color,color,transform] duration-150 active:scale-[0.98] ${
                    active ? "bg-accent-tint" : ""
                  }`}
                >
                  <span className={`sidebar-copy min-w-0 flex-1 truncate text-[14px] font-medium ${active ? "text-ink" : "text-ink-2"}`}>
                    {item.label}
                  </span>
                </button>
              );
            })}
            {query && visibleRecents.length === 0 && (
              <div className="sidebar-copy mx-2 px-2 py-2 text-[13px] text-ink-3">No backups found</div>
            )}
          </GlideGroup>
          {onViewAll && (
            <button
              type="button"
              onClick={onViewAll}
              className="sidebar-view-all sidebar-copy mx-2 mt-1 flex h-8 w-[calc(100%-16px)] items-center justify-between rounded-[8px] px-2 text-left text-[13px] font-medium text-ink-3 transition-[background-color,color,transform] duration-150 hover:bg-hover-2 hover:text-ink active:scale-[0.98]"
            >
              <span>{viewAllLabel}</span>
              <IconChevronRight size={14} aria-hidden="true" />
            </button>
          )}
        </div>

        {footerLabel && (
          <div className={`mx-2 mt-3 border-t border-line pt-3 ${collapsed ? 'w-9' : ''}`}>
            <button
              type="button"
              disabled={footerDisabled}
              aria-label={footerLabel}
              title={footerShortcut ? `${footerLabel} (${shortcutLabel(footerShortcut)})` : footerLabel}
              aria-keyshortcuts={footerShortcut}
              aria-current={footerActive ? 'page' : undefined}
              onClick={onFooterClick}
              className={`sidebar-footer relative flex h-8 w-full items-center justify-center gap-1.5 rounded-control ${footerActive ? 'bg-accent-tint text-ink' : 'text-ink-2 hover:bg-line-strong'} text-[13px] font-medium transition-[background-color,transform] duration-150 active:scale-[0.98] disabled:pointer-events-none disabled:opacity-50`}
            >
              {footerIcon && <span className={`flex shrink-0 ${footerActive ? 'text-accent-ink' : ''}`}>{footerIcon}</span>}
              {!collapsed && <span className="sidebar-copy">{footerLabel}</span>}
            </button>
          </div>
        )}
      </div>
    </aside>
  );
}
