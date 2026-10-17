#!/usr/bin/perl
# SM1153 (oom-lab L-5): the extension-list cache kept an EMPTY list after the
# extensions directory appeared beside the docroot, until deleted by hand.
#
# The cache (lazysite/cache/plugin-list.cache) was trusted for 60 seconds on its
# age alone. A dev-server set-up lists extensions once with no plugins/ yet,
# creates the directory, lists again - and is told there are none. The cache now
# records the state of what it was built from (the directory and the scripts in
# it) and is used only while that state is unchanged; and an empty list built
# because the directory is missing is not kept at all.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Plugins qw(action_plugin_list);

sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

sub widget {
    my ($d) = @_;
    make_path("$d/../plugins");
    put( "$d/../plugins/widget.pl", <<'PLUGIN' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
if ( grep { $_ eq '--describe' } @ARGV ) {
    print encode_json({ id => 'widget', name => 'Widget', description => 'x',
        version => '1.0', config_file => '', config_schema => [] });
}
PLUGIN
}

sub ids { my $r = shift; return join ',', sort map { $_->{id} } @{ $r->{plugins} } }

my $d = site_tempdir();
make_path("$d/lazysite");
put( "$d/lazysite/lazysite.conf", "site_name: T\n" );
$Lazysite::Manager::Plugins::DOCROOT = $d;
my $cache = "$d/lazysite/cache/plugin-list.cache";

my $r = action_plugin_list();
ok( $r->{ok}, 'the list answers with no extensions directory' );
is( ids($r), '', 'and is empty' );
ok( !-e $cache, 'an empty list built for a missing directory is not kept' );

widget($d);
$r = action_plugin_list();
is( ids($r), 'widget', 'the directory appearing is seen at once, not after the cache expires' );
ok( -e $cache, 'a list built from a real directory is kept' );

# And the cache is still a cache: while nothing changed it is not rebuilt.
my $old = time() - 20;
utime $old, $old, $cache;
action_plugin_list();
is( ( stat $cache )[9], $old, 'an unchanged directory leaves the cache alone' );

# A script added later is seen too.
put( "$d/../plugins/second.pl", <<'PLUGIN' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ id => 'second', name => 'Second', description => 'x',
    version => '1.0', config_file => '', config_schema => [] }) if grep { $_ eq '--describe' } @ARGV;
PLUGIN
is( ids( action_plugin_list() ), 'second,widget', 'an extension added to a listed directory is seen' );

# And one removed.
unlink "$d/../plugins/second.pl";
is( ids( action_plugin_list() ), 'widget', 'and one removed' );

done_testing;
