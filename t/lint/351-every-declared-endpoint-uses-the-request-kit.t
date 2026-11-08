#!/usr/bin/perl
# SM1369 X5, H-4 (G-4): EVERY ENDPOINT AN EXTENSION DECLARES USES THE REQUEST KIT.
#
# An extension's endpoint answers a browser directly, so the guarantees every
# core surface gives - a body capped before it is read, the token of a POST
# checked before anything runs on it - must hold there too, and must hold the
# same way. The kit is Lazysite::Endpoint (the body, the visitor key and its
# token, the POST check); the extension declares the endpoint in
# `hooks.endpoints`. For every declared script this holds, in the style of
# t/lint/263:
#
#   1. it reads no body of its own: no read of STDIN except through
#      Lazysite::Endpoint::read_body, which refuses a body over the cap unread;
#   2. it makes and checks no token of its own: no HMAC, no call of the session
#      verifier but through the kit;
#   3. every sub that reads a body calls Lazysite::Endpoint::post_guard - the
#      kit's check of the token - AFTER the read and with the extension's own id,
#      and between the two nothing of the extension's own code is called: no
#      function of a module in its payload lib, and no sub of the script that
#      reaches one.
#
# Sabotage: move the post_guard call in lazysite-odoo.pl's main() below the
# line that loads the engine (_engine), or read STDIN directly in
# _read_multipart, and this fails naming the script and the sub.
use strict;
use warnings;
use Test::More;
use File::Find;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp { open my $fh, '<', $_[0] or die "open $_[0]: $!"; local $/; return scalar <$fh> }

# The code of a script: POD and whole-line comments left out.
sub code_of {
    my ($t) = @_;
    $t =~ s/^__END__.*//ms;
    $t =~ s/^=\w+.*?^=cut\s*$//msg;
    $t =~ s/^\s*#.*$//mg;
    return $t;
}

sub subs_of {
    my ($t) = @_;
    my %s;
    $s{$1} = $2 while $t =~ /^sub (\w+) \{\n(.*?)^\}/msg;
    return %s;
}

# The modules in an extension's payload lib, by name.
sub payload_modules {
    my ($lib) = @_;
    my @m;
    return () unless -d $lib;
    find( { no_chdir => 1, wanted => sub {
                return unless -f && /\.pm\z/;
                ( my $rel = $File::Find::name ) =~ s{\A\Q$lib\E/}{};
                $rel =~ s{\.pm\z}{};
                push @m, join '::', split m{/}, $rel;
            } }, $lib );
    return @m;
}

opendir my $xd, "$root/extensions" or die "extensions/: $!";
my @desc = sort grep { /\A[a-z][a-z0-9-]*\.pl\z/ && -f "$root/extensions/$_" } readdir $xd;
closedir $xd;

my @endpoints;
for my $f (@desc) {
    my $out = qx{$^X -I"$root/lib" "$root/extensions/$f" --describe 2>/dev/null};
    my $d   = eval { decode_json($out) };
    next unless ref $d eq 'HASH' && ref $d->{owns} eq 'HASH' && ref $d->{owns}{hooks} eq 'HASH';
    my $eps = $d->{owns}{hooks}{endpoints};
    next unless ref $eps eq 'ARRAY';
    ( my $stem = $f ) =~ s/\.pl\z//;
    push @endpoints, map { { id => $d->{id}, script => $_->{script}, lib => "$root/extensions/$stem/lib" } }
        grep { ref $_ eq 'HASH' && defined $_->{script} } @$eps;
}
ok( ( grep { $_->{script} eq 'lazysite-odoo.pl' } @endpoints ), 'the Odoo page endpoint is declared and found' )
    or diag explain \@endpoints;

for my $ep (@endpoints) {
    my $s = $ep->{script};
    my $path = -f "$root/$s" ? "$root/$s" : "$root/extensions/" . ( $ep->{lib} =~ m{/extensions/([^/]+)/lib\z} )[0] . "/$s";
    ok( -f $path, "$s: the declared script is in the tree" ) or next;
    my $code = code_of( slurp($path) );

    # 1. the body
    my @direct = grep { /\b(?:sys)?read\s*\(?\s*STDIN\b|<STDIN>/ } split /\n/, $code;
    is_deeply( \@direct, [], "$s: no read of STDIN of its own" );
    like( $code, qr/\bLazysite::Endpoint::read_body\s*\(/, "$s: it reads its body through the kit" );

    # 2. no token of its own
    unlike( $code, qr/\bhmac_sha\d+/, "$s: it makes no HMAC of its own" );
    unlike( $code, qr/\bverify_csrf_token\b/, "$s: it calls the session verifier only through the kit" );

    # 3. every body read is guarded before the extension's code runs
    my %subs  = subs_of($code);
    my @mods  = payload_modules( $ep->{lib} );
    my $modre = @mods ? join( '|', map { quotemeta } sort { length $b <=> length $a } @mods ) : '(?!)';
    # a call of a payload function or method, or a load of a payload module
    my $call = qr/(?<![\$\@\%\w:])(?:$modre)::\w+\s*\(|(?<![\$\@\%\w:])(?:$modre)->\w+
        |\brequire\s+(?:$modre)\b|\brequire_payload\(\s*'(?:$modre)'/x;

    # the script's subs that reach the extension's code, to a fixed point
    my %reach = map { $_ => 1 } grep { $subs{$_} =~ $call } keys %subs;
    for ( 1 .. 10 ) {
        my $n = keys %reach;
        for my $name ( keys %subs ) {
            next if $reach{$name};
            $reach{$name} = 1 if grep { $subs{$name} =~ /(?<![\w:>\$])\Q$_\E\s*\(/ } keys %reach;
        }
        last if keys %reach == $n;
    }

    my @readers = grep { $subs{$_} =~ /\bLazysite::Endpoint::read_body\s*\(/ } sort keys %subs;
    ok( scalar @readers, "$s: at least one sub reads a body" );
    for my $name (@readers) {
        my $body = $subs{$name};
        my $r    = index( $body, 'Lazysite::Endpoint::read_body' );
        my $g    = index( $body, 'Lazysite::Endpoint::post_guard', $r );
        cmp_ok( $g, '>', $r, "$s $name(): the kit's post_guard follows the body read" ) or next;
        my $between = substr( $body, $r, $g - $r );
        my @mod_calls = $between =~ /($call)/g;
        is_deeply( \@mod_calls, [], "$s $name(): nothing of the extension's payload runs before the guard" );
        my @sub_calls = grep { $between =~ /(?<![\w:>\$])\Q$_\E\s*\(/ } sort keys %reach;
        is_deeply( \@sub_calls, [], "$s $name(): no sub that reaches the extension's code runs before the guard" );
        my ($gargs) = substr( $body, $g ) =~ /\A[^;]*?\bid\s*=>\s*'([^']*)'/s;
        is( $gargs, $ep->{id}, "$s $name(): the guard is given the extension's own id" );
    }
}

done_testing;
