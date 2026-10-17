#!/usr/bin/perl
# SM1129: ONE FUNCTION ANSWERS "IS THIS REQUEST'S IDENTITY HEADER TRUSTWORTHY".
#
# `auth_proxy_trusted: true` used to be read in two places, each deciding for
# itself (the processor's gate from the parsed conf, the manager API's by grepping
# the file), and neither asked WHERE the request came from. The hop check
# (auth_proxy_trusted_from) is only a control if every reader that honours the
# flag goes through the one function that applies it: a third reader that checked
# the flag alone would quietly be the old hole again, and nothing would look wrong.
#
# So no code outside the two definitions - Lazysite::Util::proxy_identity and the
# render path's pinned copy, request.pm's _proxy_identity (ADR 0001) - may name
# the setting as a KEY: a hash subscript, a quoted key, a conf regex. Prose in a
# log line or a report is not a read and is left alone. And the three surfaces
# that decide on identity - the processor's gate, the manager API's gate and the
# auth wrapper - must each call the function.
use strict;
use warnings;
use Test::More;
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<:utf8', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

# The code, without comments (a comment may discuss the key freely).
sub code_of {
    my ($src) = @_;
    $src =~ s/^\s*#.*$//mg;
    $src =~ s/(?<=[;{}\s])#[^\n'"]*$//mg;
    return $src;
}

# A sub's whole body, found by brace counting from its signature.
sub without_sub {
    my ( $src, $name ) = @_;
    return ( $src, 0 ) unless $src =~ /^(\s*)sub \Q$name\E\b[^\n]*\{/m;
    my $start = $-[0];
    my $i     = $+[0];
    my $depth = 1;
    while ( $depth && $i < length $src ) {
        my $c = substr $src, $i++, 1;
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
    }
    substr( $src, $start, $i - $start ) = '';
    return ( $src, 1 );
}

my @files;
File::Find::find(
    {   no_chdir => 1,
        wanted   => sub {
            my $p = $File::Find::name;
            (my $r = $p) =~ s{^\Q$root\E/?}{};
            return if $r =~ m{\A(?:t|tmp|docs|dist|\.git|debian|installers)(?:/|\z)};
            return unless -f $p && $p =~ /\.(?:pl|pm)\z/;
            push @files, $p;
        },
    },
    $root
);
cmp_ok( scalar @files, '>', 20, 'the sweep found the engine code' );

# A KEY-LIKE mention: {auth_proxy_trusted}, 'auth_proxy_trusted', a conf regex
# ^auth_proxy_trusted\s, or a word in a qw() list. A prose mention is followed by
# a colon-and-value or a space inside a sentence, and is preceded by a space.
my $KEYLIKE = qr/(?:[{'"^]|\bqw\([^)]*?\b)auth_proxy_trusted(?:_from)?(?:[}'"]|\\s|\\b|\s*=>)/;

my @readers;
my %definition_seen;
for my $p (@files) {
    ( my $rel = $p ) =~ s{^\Q$root\E/}{};
    my $code = code_of( slurp($p) );
    for my $def ( [ 'lib/Lazysite/Util.pm', 'proxy_identity' ], [ 'lazysite-processor/request.pm', '_proxy_identity' ] ) {
        next unless $rel eq $def->[0];
        my ( $rest, $found ) = without_sub( $code, $def->[1] );
        $code = $rest;
        $definition_seen{$rel} = $found;
    }
    while ( $code =~ /($KEYLIKE)/g ) {
        my $line = 1 + ( () = substr( $code, 0, $-[0] ) =~ /\n/g );
        push @readers, "$rel (about line $line): $1";
    }
}

ok( $definition_seen{'lib/Lazysite/Util.pm'},                 'the module defines proxy_identity' );
ok( $definition_seen{'lazysite-processor/request.pm'},        "the render path carries its pinned copy, _proxy_identity" );
is_deeply( \@readers, [], 'no other code reads auth_proxy_trusted or auth_proxy_trusted_from as a key' )
    or diag join "\n", @readers;

# The three deciding surfaces call the one function. SM1131: and so does the
# identity reader, Lazysite::Auth::Identity::request_identity, which decides
# whether the CONFIGURED header names count - from proxy_identity's answer, or
# from the answer its caller already holds for this request (the processor passes
# its pinned copy's), never from the flag (the key sweep above holds that).
my %MUST = (
    'lazysite-processor.pl'         => qr/\b_proxy_identity\s*\(/,
    'lazysite-manager-api.pl'       => qr/Lazysite::Util::proxy_identity\s*\(/,
    'lazysite-auth.pl'              => qr/Lazysite::Util::proxy_identity\s*\(/,
    'lib/Lazysite/Auth/Identity.pm' => qr/Lazysite::Util::proxy_identity\s*\(/,
    'lazysite-processor/auth.pm'    => qr/\bproxy\s*=>\s*_proxy_identity\s*\(/,
);
for my $rel ( sort keys %MUST ) {
    like( code_of( slurp("$root/$rel") ), $MUST{$rel}, "$rel asks the one function" );
}

done_testing();
