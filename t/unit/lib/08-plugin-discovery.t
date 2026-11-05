#!/usr/bin/perl
# An extension dropped into extensions/ is discovered by action_extension_list without
# editing a hard-coded list (SM083: stats.pl was previously invisible).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Extensions qw(action_extension_list);

my $root = tempdir( CLEANUP => 1 );
make_path( "$root/public_html/lazysite", "$root/extensions" );
open my $cf, '>', "$root/public_html/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;

# A minimal valid extension (id 'widget') dropped in - not in any hard-coded list.
open my $pf, '>', "$root/extensions/widget.pl" or die $!;
print $pf <<'EXTENSION';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
if ( grep { $_ eq '--describe' } @ARGV ) {
    print encode_json({ id => 'widget', name => 'Widget', description => 'x',
        version => '1.0', config_file => '', config_schema => [] });
}
EXTENSION
close $pf;
# A non-extension .pl that does not --describe must be dropped, not listed.
open my $junk, '>', "$root/extensions/notaextension.pl" or die $!;
print $junk "#!/usr/bin/perl\nprint qq(noise\\n);\n";
close $junk;

$Lazysite::Manager::Extensions::DOCROOT = "$root/public_html";

my $r = action_extension_list();
ok( $r->{ok}, 'extension-list ok' );
my %ids = map { $_->{id} => 1 } @{ $r->{extensions} };
ok( $ids{widget}, 'a freshly dropped extensions/*.pl is discovered dynamically' );
ok( !$ids{notaextension}, 'a .pl without a valid --describe is not listed' );

done_testing;
