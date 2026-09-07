#!/bin/sh

# Renders the Aerium logo over an existing icon PNG, keeping its dimensions.
# Usage: icons.sh <path-to-png>
svg=$(dirname "$0")/aerium.svg
w=$(identify -format %w "$1")

# No field behind the mark. The logo is the whole icon.
#
# This has now been three things. It was #FFFFFF, on the reasoning that a small
# mark on a plain light tile reads like the stock Phone, Messages and Camera
# icons beside it. android issue 13 reported that as "very goofy" and it was:
# aerium.svg is not a glyph that needs a field, it is a full-colour disc that is
# already its own tile, so a second tile behind it reads as a border. It then
# became #111C42, the darkest navy of the mark itself, so that whatever the
# launcher mask left uncovered was at least a colour the disc already touches.
#
# That was still a tile. Asked for directly, against the Windows build as the
# reference: just the logo, nothing behind it. So there is nothing behind it -
# the background layer is fully transparent and the legacy bitmaps are drawn on
# transparency too.
#
# This is what the mark is shaped for. A 512 viewBox filled edge to edge by one
# disc has no corners to lose, so on a circular or squircle mask the result is
# the disc and only the disc, and there is no field left to show as a rim at
# any mask shape.

# The logo is a circle that fills its whole 512 viewBox, so these percentages
# are the circle's diameter as a share of the icon's width.
#
# An adaptive icon is a 108dp canvas of which the launcher shows the middle
# 72dp, so a disc drawn at 72/108 = 66.7% has exactly the diameter of the
# visible circle. That is the largest the mark can be without the mask cutting
# into it, and it is what "bigger" means here: the previous 36% put the disc at
# 38.9dp inside a 72dp tile, a little over half the width and just under a
# third of the area, with the rest of the tile white.
#
# 68 rather than 66.7 so the disc passes the mask boundary by a fraction of a
# dp instead of landing on it. Masks are antialiased and launchers do not all
# use the same one; a disc that stops exactly at the edge can leave a hairline
# of background, and a hairline is the artifact this is meant to remove.
# Overshooting costs nothing, because what it clips is the outer edge of a disc
# whose colour the background already matches.
#
# themed_app_icon.xml stays at 0.40 and is not rendered here. It must not
# follow this change: the system tints that layer one flat colour, so a mark
# filling the visible circle tints the whole tile and the icon becomes a
# featureless blob - which is exactly what it did at 0.66 before. A monochrome
# layer wants to be a small glyph on a field; that reasoning still holds for
# it, and only for it. See the comment in that file.
#
# layered_app_icon_foreground.xml also stays at 0.36 and is likewise not
# rendered here. Its <group> is stripped entirely when theme.sh derives the
# search-widget drawable from it, so that scale reaches nothing that ships and
# changing it would only break theme.sh's translateY anchor.
#
# A legacy icon has no 108dp canvas - the whole PNG is what the launcher masks
# - so the equivalent of "fills the visible circle" is the full width of the
# file.
adaptive_pct=68
legacy_pct=100

# Draws the logo at $2 percent of the icon width, centred on background $3.
# Pass 'none' for a transparent background.
render_over() {
    fg=$((w * $2 / 100))
    rsvg-convert -w $fg -h $fg "$svg" -o "$1.fg.png"
    convert -size ${w}x${w} xc:"$3" "$1.fg.png" -gravity center -composite "$1"
    rm -f "$1.fg.png"
}

case $(basename "$1") in
  layered_app_icon_background*)
    # Adaptive icon background layer: fully transparent. The launcher masks the
    # two layers and leaves transparency transparent - it does not substitute a
    # plate of its own for an adaptive icon, which is the difference between
    # this and the legacy case below - so what survives the mask is the
    # foreground disc by itself.
    convert -size ${w}x${w} xc:none "$1" ;;
  layered_app_icon_foreground*)
    # Adaptive icon foreground layer: the logo on transparency, because the
    # background layer above is what supplies the colour behind it.
    render_over "$1" $adaptive_pct none ;;
  *)
    # Everything else - layered_app_icon.png and app_icon.png - is a legacy,
    # non-adaptive icon: one square bitmap, no separate background layer.
    #
    # Drawn on transparency, at 100%, so the disc inscribes the square exactly
    # and the only empty pixels are the four corners it cannot reach.
    #
    # The honest caveat, since it is the one thing here that is not fully ours
    # to decide: a launcher that falls back to legacy treatment wraps a
    # non-adaptive icon in a plate of its own choosing, and a painted field was
    # how the previous version denied it the chance. That fallback needs an app
    # with no adaptive icon, and this one has both layers above, so the launcher
    # uses those. Where the legacy bitmap is still read directly - the task
    # switcher and parts of Settings on some builds - a plate can come back.
    # Named rather than left to be discovered: if it does, this line is the one
    # to change back, and only this line.
    render_over "$1" $legacy_pct none ;;
esac
echo "aerium icon: $1 (${w}px)"
