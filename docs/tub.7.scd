tub(7)

# NAME

tub - Toast's UEFI Bootloader

# DESCRIPTION

Tub is a UEFI bootloader capable of loading arbitrary UEFI payloads with
UCS-2 ExtraData as a cmdline. It is explicitly compatible with standalone UEFI
payloads (such as various tools, including the UEFI shell) and EFI stubs
(whether the built-in kernel one or UKI stubs).

Tub will gather various UEFI boot options on your system into groups, then
present you with a menu to select which you wish to boot. The intended uses are:

- Minimizing management of kernel versions. You will generally want the same
cmdline across all versions of a kernel for a given boot profile. With tub's
configuration you only specify the cmdline once for the entire group. With the
sorting options, the latest one is always at the top.
- Minimizing management of boot options. You should be able to drop in various
UEFI tools or other boot entries into already configured locations and have them
be picked up automatically alongside the rest.
- Compatibility with distribution management in the case of multi-booting. A distribution can ship their own tub configuration file, which you may then include in your main configuration. If you want to switch your default distribution, you simply switch the order of the includes.
- Being the default bootloader for an ESP. The default configuration (not yet
implemented) should make tub be an appropriate default bootloader in the case
a boot entry is not configured.

It is expected that most tub configurations will typically be 1-2 lines.

# CONFIGURATION

Tub will read its configuration from a "tub.conf" file in the root of the ESP it
is on. Booting from other device types (such as the network) is theoretically
possible under the condition that a valid device pointer exists, and the
simplefilesystem protocol is implemented for it.

See _tub.conf_(5) for more details on the configuration file format.

The default configuration (if a config file could not be found) is:
```
pr:**.efi:Discovered EFI files (%n):%p:
```

## Boot Groups

Boot options in tub are grouped into Boot Groups. Each boot group corresponds to
exactly one line in the configuration file.

## Default Boot

On startup, a timer is started for *!timeout* seconds (if timeout is set to >0).
At the end of this timer, if no keys have been pressed up to that point, the
default boot option will be automatically picked.

The default boot option is the first option that matches the default directive
(or simply the first option in the first non-empty group if that's empty). Note
that the glob is performed against an internal representation of the path. See
_tub.conf_(5) for recommendations on how to compose your pattern.

# SELECTION MENU

The selection menu is an interactive TUI-style application. If there are too
many options to display (the displayable amount is configured by the *!pagelen*
directive, defaulting to 10), then the menu is paginated. Here are the
available key bindings:

[[ *Input*
:< *Action*
|  Down Arrow
:  Move the selection cursor down.
   If the cursor is at the bottom, try to scroll the page down.
|  Up Arrow
:  Move the selection cursor up.
   If the cursor is at the top, try to scroll the page up.
|  Page Down
:  Try to scroll the page down by the page size.
   If this amount of scrolling is impossible, scroll to the bottom.
   If the page window is already at the end of the available options,
   move the cursor to the bottom.
|  Page Up
:  Try to scroll the page up by the page size.
   If this amount of scrolling is impossible, scroll to the top.
   If the page window is already at the start of the available options,
   move the cursor to the top.
|  Right Arrow, Enter
:  Select the current option.
   Note that empty boot groups may not be selected, making this a no-op.
|  Left Arrow, Escape
:  If you are in the boot option menu, return to the group selection menu.
|  Delete
:  Reboot the system.
|  Home
:  Exit the bootloader, dropping back to the UEFI option selection screen.
|  a-z
:  Select the option corresponding to the label on screen.
   This is exactly equivalent to scrolling to it with arrow keys + enter.
   If there's no such label on screen, the input is ignored.
|  A-Z
:  Like a-z.
   It is planned to have this instantly select the top boot option
   when selecting a Boot Group.
   It is planned to have this open a line editor to edit the cmdline
   when selecting a Boot Option.

# SEE ALSO

_tub.conf_(5)
