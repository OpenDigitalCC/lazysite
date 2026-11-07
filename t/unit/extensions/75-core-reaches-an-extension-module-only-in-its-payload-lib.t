#!/usr/bin/perl
# SM1369 X7, part one (ruling 135): CORE REACHES AN EXTENSION'S MODULE ONLY IN
# THE EXTENSION'S PAYLOAD LIB, BESIDE CORE'S OWN.
#
# Lazysite::Extensions::require_payload is how the core lines that still call an
# extension's module by name (lint 321's allow-list, until each hook slice) load
# it, now that Odoo's modules live in extensions/odoo/lib. Against a real fixture
# engine tree (lib/ with the two modules it needs, extensions/ beside it), each in
# a fresh perl with only that lib on @INC, as a deployed CGI has:
#
#   - the module is loaded from the payload lib beside the lib core came from, and
#     that lib goes on @INC (appended, the X1 rule); a second call is a no-op;
#   - a copy of the module in core's lib - what an edited file an earlier release
#     installed there leaves behind, which the upgrade keeps with an orphan
#     warning - is refused by name, rather than the stale copy winning;
#   - a module in two payload libs is refused, naming both;
#   - a module in no payload lib dies as `require` does, so an `eval` reads the
#     same; a payload linked in, or a descriptor missing, is no payload;
#   - the processor's _lazy_lib falls back to it for a module that is not core's.
#
# Sabotage: drop the shadow loop from require_payload and the stale-copy case loads
# the stale copy - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $repo = repo_root();
my $t    = site_tempdir();    # a docroot; its tree is the fixture engine root
( my $root = $t ) =~ s{/[^/]+\z}{};
make_path("$root/lib/Lazysite");
copy( "$repo/lib/Lazysite/$_.pm", "$root/lib/Lazysite/$_.pm" ) or die "$_: $!" for qw(Extensions Paths);

sub spit {
    my ( $p, $s ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $s;
    close $fh;
}
sub module { my ( $pkg, $says ) = @_; return "package $pkg;\nsub says { '$says' }\n1;\n" }

spit( "$root/extensions/demo.pl", "#!/usr/bin/perl\n" );
spit( "$root/extensions/demo/lib/Demo/Thing.pm", module( 'Demo::Thing', 'payload' ) );

sub ask {
    my ($code) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $r = run_child( [ $^X, "-I$root/lib", '-e', "use Lazysite::Extensions; $code" ] );
    return ( ( $r->{out} // '' ) . ( $r->{err} // '' ) );
}

like( ask('Lazysite::Extensions::require_payload("Demo::Thing"); print Demo::Thing::says(), " ", $INC{"Demo/Thing.pm"}, " ", $INC[-1], "\n"'),
    qr{\Apayload \Q$root\E/extensions/demo/lib/Demo/Thing\.pm \Q$root\E/extensions/demo/lib\n},
    'loaded from the payload lib beside core\'s lib, which is appended to @INC' );
like( ask('print Lazysite::Extensions::engine_root(), "\n"'), qr{\A\Q$root\E\n}, 'the engine root is where core\'s lib is' );
like( ask('Lazysite::Extensions::require_payload("Demo::Thing") for 1 .. 2; print scalar( grep { m{/demo/lib\z} } @INC ), "\n"'),
    qr/\A1\n/, 'a second call adds nothing' );

# a stale copy in core's lib
spit( "$root/lib/Demo/Thing.pm", module( 'Demo::Thing', 'stale' ) );
my $out = ask('eval { Lazysite::Extensions::require_payload("Demo::Thing"); 1 } or print "refused: $@"; print "says: ", ( defined &Demo::Thing::says ? Demo::Thing::says() : "nothing" ), "\n"');
like( $out, qr{refused: Demo/Thing\.pm is in the payload lib \Q$root\E/extensions/demo/lib and also at \Q$root\E/lib/Demo/Thing\.pm}, 'a copy in core\'s lib is refused by name' );
like( $out, qr/says: nothing/, '...and nothing is loaded' );
unlink "$root/lib/Demo/Thing.pm" or die $!;

# two payloads
spit( "$root/extensions/other.pl", "#!/usr/bin/perl\n" );
spit( "$root/extensions/other/lib/Demo/Thing.pm", module( 'Demo::Thing', 'other' ) );
like( ask('eval { Lazysite::Extensions::require_payload("Demo::Thing") } or print $@'),
    qr{Demo/Thing\.pm is in more than one extension's payload lib}, 'a module in two payload libs is refused' );
unlink "$root/extensions/other.pl" or die $!;
like( ask('Lazysite::Extensions::require_payload("Demo::Thing"); print Demo::Thing::says(), "\n"'),
    qr/\Apayload\n/, 'a payload with no descriptor beside it is no payload' );

# none
like( ask('my $ok = eval { Lazysite::Extensions::require_payload("Demo::Absent"); 1 }; print $ok ? "loaded" : "died: $@"'),
    qr{\Adied: Can't locate Demo/Absent\.pm in any extension's payload lib}, 'a module in no payload lib dies, as require does' );
like( ask('my $ok = eval { Lazysite::Extensions::require_payload("not a name"); 1 }; print $ok ? "loaded" : "died: $@"'),
    qr/\Adied: require_payload: 'not a name' is not a module name/, 'and a name that is not a module is refused' );

# a linked payload
rename "$root/extensions/demo", "$root/demo-elsewhere" or die $!;
symlink "$root/demo-elsewhere", "$root/extensions/demo" or die $!;
like( ask('eval { Lazysite::Extensions::require_payload("Demo::Thing"); 1 } or print "refused: $@"'),
    qr/\Arefused: Can't locate/, 'a payload linked in from elsewhere is no payload' );
unlink "$root/extensions/demo" or die $!;
rename "$root/demo-elsewhere", "$root/extensions/demo" or die $!;

# the processor's lazy loader falls back to it
{
    my $proc = "$repo/lazysite-processor.pl";
    open my $fh, '<', $proc or die $!;
    my ($body) = do { local $/; <$fh> } =~ m{^sub _lazy_lib \{\n(.*?)^\}}ms;
    close $fh;
    like( $body // '', qr/Lazysite::Extensions::require_payload\(\$module\)/,
        '_lazy_lib reaches a module that is not core\'s through require_payload' );
}

done_testing();
