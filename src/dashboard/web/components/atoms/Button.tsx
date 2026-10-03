"use client";

import { ButtonHTMLAttributes } from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const filledShadow = "shadow-[inset_0_1px_0_rgba(255,255,255,0.14)]";

/* Pill-shaped by default — the app's core button style. Explicit symmetric
 * padding (not a fixed height) so the top/bottom spacing is always equal.
 *
 * The scale, tallest last so a smaller size is never the taller one:
 *   xs 26px · sm 28px · md 32px              — pills, for buttons with words
 *   icon-sm 28px · icon 32px                 — squares, for buttons that are only an icon
 * Icon-only buttons (close, refresh, theme, dismiss) are all the same rounded square, whatever the glyph inside. */
export const buttonVariants = cva(
  `inline-flex items-center justify-center font-medium select-none
   transition-[transform,background-color,opacity] duration-150 ease-out
   active:scale-[0.96] disabled:opacity-50 disabled:pointer-events-none`,
  {
    variants: {
      variant: {
        primary: `bg-ink text-canvas hover:opacity-90 ${filledShadow}`,
        /* hover-2, not inset: inset is 1.06:1 from the surface in both themes, so that hover could not be seen */
        secondary: "bg-surface text-ink shadow-btn hover:bg-hover-2 aria-expanded:bg-hover",
        /* white on the light theme's teal, but the dark theme's teal is a light one (1.7:1 with white), so it takes the page's dark ink */
        accent: `bg-accent text-white dark:text-page hover:bg-accent-ink ${filledShadow}`,
        /* the text-grade green: the fill green is 3.6:1 with white, and the dark theme's text-grade green is a light one */
        success: `bg-green-ink text-white dark:text-page hover:brightness-95 ${filledShadow}`,
        /* transparent until hovered — for dense toolbars/action rows */
        quiet: "text-ink hover:bg-hover",
      },
      size: {
        /* compact pill — fixed height, lighter weight */
        xs: "h-6.5 rounded-full px-2.5 text-[12px] font-normal leading-none gap-1",
        /* canonical action pill — 28px tall, roomy sides */
        sm: "h-7 px-3 text-[13px] leading-none rounded-full gap-1.5",
        md: "px-4 py-[9px] text-sm leading-none rounded-full gap-2",
        /* icon only: a rounded square, never squeezed by a flex row */
        icon: "size-8 shrink-0 rounded-control p-0",
        "icon-sm": "size-7 shrink-0 rounded-control p-0",
      },
    },
    defaultVariants: { variant: "secondary", size: "md" },
  },
);

export type ButtonVariant = NonNullable<VariantProps<typeof buttonVariants>["variant"]>;

export type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & VariantProps<typeof buttonVariants>;

export function Button({
  variant,
  size,
  className,
  ...props
}: ButtonProps) {
  return <button className={cn(buttonVariants({ variant, size }), className)} {...props} />;
}
