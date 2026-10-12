#!/usr/bin/perl
# SM1014: a group picker in the manager names a group @name.
#
# RULED by the release manager on 2026-10-12: "groups should be prefixed with
# something say @ so they can be distinguished from users, and this should be
# consistent anywhere a group is picked".
#
# WHY THIS IS A LINT. It was already the rule on two pages and not on two
# others, and the difference was one argument: mgPrincipalSelect() took a
# `groupPrefix`, and Groups and Domains passed ''. Each choice was reasonable
# where it was made, which is how a product ends up naming one group two ways.
# The option is retired; this holds that it stays retired, that the shared
# picker labels every group through mgGroupLabel(), and that the pages which
# draw a group by hand - a pill, a hand-built option - do too.
#
# Display only. The stores keep their own form (an ACL rule names `@staff`,
# allowed_groups and a group's member list `staff`); that is the pages' and the
# tests' business (t/unit/manager/282), not a lint's.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PageScript qw(extract_function page_source);
use TestHelper qw(repo_root);

my $root   = repo_root();
my $layout = "$root/starter/lazysite/manager/layout.tt";

my @pages;
for my $d ( "$root/starter/manager", "$root/starter/lazysite/manager" ) {
    next unless -d $d;
    find( { no_chdir => 1, wanted => sub { push @pages, $_ if /\.(?:md|tt)\z/ && -f $_ } }, $d );
}
@pages = sort @pages;
cmp_ok( scalar @pages, '>=', 8, 'found the manager pages' );

# Code only: a line comment, a TT comment and the style guide's specimens are
# prose about controls, not controls.
sub code_of {
    my ($p) = @_;
    my $text = page_source($p);
    $text =~ s/\[%\#.*?%\]//gs;
    return join "\n", grep { !m{^\s*(?://|\#|\*)} } split /\n/, $text;
}

sub rel { ( my $r = $_[0] ) =~ s{\A\Q$root/\E}{}; return $r }

# --- the retired option ------------------------------------------------------
{
    my @passing = map { rel($_) } grep { code_of($_) =~ /\bgroupPrefix\b/ } @pages;
    is_deeply( \@passing, [], 'no manager page names groups through a groupPrefix' )
        or diag( join "\n  ", '', @passing, '',
        'groupPrefix was how a picker named a group plainly. A group is @name',
        'in every picker (SM1014); mgPrincipalSelect() does it for you.' );
}

# --- the shared picker -----------------------------------------------------
{
    my $src = page_source($layout);
    my ($label) = $src =~ /(window\.mgGroupLabel = function.*?\n    \};)/s;
    ok( $label, 'the layout defines mgGroupLabel' );
    like( $label // '', qr/'\@' \+ g/, 'which puts the @ in front of a group' );
    ok( $src =~ /window\.mgGroupName = function/, 'and mgGroupName, which takes it off' );
    my ($opts) = $src =~ /(window\.mgPrincipalOptions = function.*?\n    \};)/s;
    ok( $opts, 'the layout defines mgPrincipalOptions' );
    like( $opts // '', qr/GROUPS\.forEach\(.*?all\.push\(window\.mgGroupLabel\(g\)\)/s,
        'and its group options are mgGroupLabel(g)' );
}

# --- a group drawn by hand ---------------------------------------------------
# A page that builds an <option> or a pill from a group variable directly - not
# through mgGroupLabel - names the group plainly. Matched on the shapes this
# repository uses: the value concatenated straight in, or escaped and
# concatenated.
{
    my $var  = qr/(?:g|grp|group|GROUPS\[\w+\]|current\[\w+\])/;
    my $bare = qr/(?:escHtml|esc)?\(?\s*$var\s*\)?\s*\+/;
    my @hand;
    for my $p ( grep { $_ ne $layout } @pages ) {
        my $n = 0;
        for my $line ( split /\n/, code_of($p) ) {
            $n++;
            next if $line =~ /mgGroupLabel/;
            push @hand, rel($p) . ": $line"
                if $line =~ /<option value="' \+ $bare/
                || $line =~ /class="mg-token">' \+ $bare/;
        }
    }
    is_deeply( \@hand, [], 'no page draws a group option or pill without mgGroupLabel' )
        or diag( join "\n  ", '', @hand, '',
        'Show a group as mgGroupLabel(name). Store what the store holds:',
        'mgGroupName(value) takes the @ back off where the store keeps names.' );
}

# --- the pages that draw groups, by name ---------------------------------------
# The generic match above cannot see a helper whose parameter is called
# something else (domains.md's tokenPill(v, kind)), so the four that draw a
# group are named, with the page they are on.
my %DRAWS_A_GROUP = (
    'starter/manager/groups.md'     => [qw(memberPillsHtml addMember)],
    'starter/manager/users.md'      => [qw(renderNewUserGroups addNewUserGroupFromInput)],
    'starter/manager/domains.md'    => [qw(tokenPill addToken)],
    'starter/manager/connectors.md' => [qw(callersField callersValue)],
);
for my $page ( sort keys %DRAWS_A_GROUP ) {
    my $src = page_source("$root/$page");
    for my $fn ( @{ $DRAWS_A_GROUP{$page} } ) {
        my $body = extract_function( $src, $fn, $page );
        like( $body, qr/mgGroup(?:Label|Name)\(/, "$page: $fn names a group through the layout" );
    }
}

done_testing();
