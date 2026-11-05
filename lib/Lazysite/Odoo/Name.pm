package Lazysite::Odoo::Name;

# SM1328 (ruling 52, T-13): THE NAME A PERSON KNOWS ODOO BY - the one reader of
# `odoo_display_name`, so the setting moves with the extension in one piece.
#
#   odoo_display_name: Odoo     in lazysite/odoo.conf. Absent is "Odoo", what every
#                               text said before the setting; any value is that name;
#                               an empty value is no name at all
#
# Every dialog label and error text a visitor or a manager reads that speaks of Odoo
# as the system they use - signing in to it, it answering, refusing or not being
# reached, a change made in it - is said through phrase(): each such text is written
# twice, with the name and without, so an empty name never leaves a sentence with a
# hole in it. The extension's own name ("the Odoo extension", the Odoo page), the
# daemon, configuration keys and their labels, logs and operator docs keep "Odoo".
use strict;
use warnings;

our $DEFAULT = 'Odoo';

# The name, '' for none. A value is one line already (the extension's config save
# refuses a line break); its outer spaces go.
sub display_name {
    my ($dir) = @_;
    require Lazysite::Odoo::SiteSignin;
    my $v = Lazysite::Odoo::SiteSignin::conf($dir)->{odoo_display_name};
    return $DEFAULT unless defined $v;
    $v =~ s/\A\s+|\s+\z//g;
    return $v;
}

# phrase( $named, $plain, $dir ): $named with every {name} replaced by the name, or
# $plain when the name is empty.
sub phrase {
    my ( $named, $plain, $dir ) = @_;
    my $n = display_name($dir);
    return $plain unless length $n;
    ( my $t = $named ) =~ s/\{name\}/$n/g;
    return $t;
}

1;
