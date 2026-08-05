tub(5)

# NAME

tub.conf - tub configuration file

# DESCRIPTION

The tub configuration file is composed of boot configurations, directives, and
comments, in the order of interest to the user. Each is treated in its own
session, in this same order.

# BOOT CONFIGURATION

If a line is neither a directive nor a comment, it is treated as a boot
configuration. Well-formed boot configurations are lines of 5 *:*-separated
fields. These fields, in order, are:

- The sort flags, configuring how boot options in each boot group are sorted.
- The file pattern, which determines which files are considered part of the boot
group.
- The group format string, which determines how a boot group is displayed.
- The option format string, which determines how a group's boot options are displayed.
- The command line common to all options in a given boot group.

## Sort Flags

Each sort flag is a single letter, like *r* or *R*. By convention, capital
letters are the inverse of their lowercase equivalents. Later flags override
previous flags. The currently available flags are:

- *p*: consider the full path of the file, as opposed to only the basename.
- *r*: order the boot options in reverse order. For example, *distro-1.2.3.efi* will be ordered after *distro-1.2.4.efi* with this setting.

## File Pattern

A simple file pattern corresponds to the literal file. You may use backslashes
as is the UEFI convention, or forward slashes (which will be translated into
backslashes).

If the pattern is a simple pattern (i.e. it does not contain an asterisk), it
will not be verified, meaning that if the file does not actually exist, it will
still be displayed.

It is expected that most patterns will be globbing patterns (i.e. will contain
asterisks). Globs may appear anywhere in the pattern, and their number is
unlimited, but they will never match a directory. For example, */fo\*o/\*.efi*
will match */foo/bar.efi* but will not match */foo/bar/baz.efi*.

All matching files (i.e. not directories) will be added as boot options, whether
or not they are truly bootable.

## Group Format String

The group format string determines how each group will be displayed on the
screen to refer to it. It supports the following escape sequences:

- *%%*: a literal *%*
- *%n*: the number of options in the group. It is recommended to end group
format strings in *(%n)* or similar.

## Option Format String

The option format string determines how each option in a boot group will be
displayed on the screen to refer to it. It supports the following escape
sequences:

- *%%*: a literal *%*
- *%p*: the path to the boot option, as will be used to construct the DevicePath
to pass to LoadImage.
- *%f*: the filename taken from *%p*. This is defined as everything after the
final directory separator, else the entire path if there are none.
- *%b*: the basename taken from *%f*. This is defined as everything up to the
final *.*, else the entire filename.
- *%e*: the extension taken from *%f*. This is defined as everything after the
final *.*, else the empty string.
- *%d*: the dirname taken from *%p*. This is defined as everything up to the
final directory separator, else the empty string.
- *%c*: the cmdline configured for the boot option. Note that this is the same
for all options, but is only useful here.
- *%g*: the group the option is in, displayed as per the group format string.

## Cmdline

If this is non-empty (including spaces), it will be passed as-is to the boot
option payload via LoadedImage protocol's Extra Data, after being converted to
UCS-2. This may contain literal *:*s, it will include everything from its
opening *:* to the end of the line, excluding the newline.

# DIRECTIVES

A directive is a line that starts with a *!*. It is identified by the first
character after the *!*, but it is recommended to type out the entire directive
nonetheless. The payload is everything after the first set of spaces on the
line. The available directives are:

- *!default*: A globbing pattern that the internal representation of each boot
option path will be compared against. The first matching one is selected as the
default boot option. To disable globbing, have a line with just "!default" in
it. Since the internal representation is not particularly intuitive, it is
recommended to set this to something like *\*myfile.efi*, if at all.
- *!timeout*: How long to wait until booting the default option, in seconds. Set
to 0 to disable the default boot timer. The maximum value is 255, i.e. 4 minutes
and 15 seconds.
- *!pagelen*: How many entries to show in each "page" window, at most. Defaults
to 5, cannot be greater than 27, and must be at least 1. Setting it to 0 or
a number above 27 is the same as setting it to 27.
- *!include*: A file to include in-line, as though its contents were pasted in
the location of the directive. The payload does not support globbing, but you
may use slashes or backslashes as directory separators.

# COMMENTS

Lines beginning by a *#* or that contain only a newline characger are ignored.

```
# this is a comment
#so is this

# the above line is ignored
```

# EXAMPLES

```
# this is a comment
# the below line is ignored

# this configuration line will create a boot group named "Example Linux"
# and allow the user to pick any file under ESP\\linux\\
# that starts with "example-" and ends in ".efi"
# they will be displayed as "example-"... up to, but excluding ".efi"
# and will be booted with no cmdline
:/linux/example-*.efi:Example Linux:%b:

# this configuration is like the above, but in reverse order
# and with "rootwait rw" as the cmdline
# reverse order is useful to order newer kernel versions above older ones
r:/linux/example-*.efi:Example Linux:%b:rootwait rw

# this is a typical example to allow dropping in UEFI tools into ESP\\tools
:/tools/*.efi:Tools:%b:
```

# SEE ALSO

_tub_(7)
