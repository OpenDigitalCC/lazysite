package Lazysite::Ext::AppOffline;

# SM1396 (ruling 53): the offline kit's one hook function - the layout variable
# [% app_offline_kit %] (owns.hooks.template_vars in extensions/app-offline.pl),
# called by core through Lazysite::Extensions::Hooks with { docroot, lazysite_dir,
# version } while the extension, and Odoo which it requires, is on. The kit
# itself is assets/kit.js, served by the engine at the path the declaration
# gives it (/assets/app-offline-kit.js).
#
# Named Lazysite::Ext::<Extension>, the shape ruling 68 (D-3) gives an
# extension's own modules.

use strict;
use warnings;

our $PATH = '/assets/app-offline-kit.js';

# The script tag, versioned with the engine as every engine asset is, so a
# release reaches an installed app on its next check. Safe markup: the version
# is the engine's own, reduced to the characters a version holds.
sub kit_tag {
    my ($ctx) = @_;
    my $v = ref $ctx eq 'HASH' && defined $ctx->{version} ? $ctx->{version} : '';
    $v =~ s/[^A-Za-z0-9._-]//g;
    return '<script src="' . $PATH . '?v=' . $v . '" defer></script>';
}

1;
