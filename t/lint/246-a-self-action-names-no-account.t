#!/usr/bin/perl
# SM1043 (SM1034, ruled 2026-10-12): a `self` action acts on the signed-in caller
# and on nobody else, BY CONSTRUCTION - no parameter names an account, so there is
# nothing to check and nothing to get wrong. This lint holds the construction:
#
#   1. every me / me-* action is declared self (a new one cannot skip it)
#   2. a self action is cookie-only (absent from %GATE), carries the reason a
#      token is refused, and declares no parameter that names an account
#   3. its dispatch branch passes the handler nothing - the handler takes the
#      account from the request context, never from an argument
#   4. Lazysite::Manager::Account, where the handlers live, reads no query
#      parameter at all and no account-naming key of the request body
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                    qw(repo_root);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();
my %A    = %Lazysite::ControlApi::Actions::ACTION;
my %GATE = %Lazysite::ControlApi::Actions::GATE;
my %SELF = Lazysite::ControlApi::Actions::self_actions();

ok( scalar keys %SELF, 'there are self actions to hold' );

for my $name ( sort grep { /\Ame(?:-|\z)/ } keys %A ) {
    ok( $SELF{$name}, "$name is declared self" );
}

for my $name ( sort keys %SELF ) {
    ok( !exists $GATE{$name}, "$name: no token reaches it (absent from the gate)" );
    ok( length( $A{$name}{cookie_only_reason} // '' ), "$name: says why a token is refused" );
    for my $p ( @{ $A{$name}{params} || [] } ) {
        ok( !Lazysite::ControlApi::Actions::self_param_names_account( $p->{name} ),
            "$name: parameter '$p->{name}' does not name an account" );
    }
}

my $api = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/;
    <$fh>;
};
for my $name ( sort keys %SELF ) {
    like( $api, qr/elsif \( \$action eq '\Q$name\E' \)\s*\{ \$result = (?:action|dispatch)_[a-z0-9_]+\(\) \}/,
        "$name: the dispatcher passes the handler no argument" );
}

# SM1057 x SM1043: the manager door lets self actions past its `ui` gate, and the
# set it lets past is the declaration's - not a list of names kept beside the
# gate, which the checks above would not hold.
like( $api, qr/my %SELF_ACTION = Lazysite::ControlApi::Actions::self_actions\(\);/,
    'the ui gate\'s exemption is read from the self declaration' );
like( $api, qr/unless \(\s*\$SELF_ACTION\{\$action\}\s*\|\|\s*\$caps->\{manager_ui\}/,
    'and it is the ui gate that consults it' );

my $mod = do {
    open my $fh, '<', "$root/lib/Lazysite/Manager/Account.pm" or die $!;
    local $/;
    <$fh>;
};
( my $code = $mod ) =~ s/^\s*#.*$//mg;
unlike( $code, qr/\$params\{|%params/, 'Account.pm reads no query parameter' );
# The request body is read one way only - into $req - so what is read from it is
# visible as $req->{...}, and none of it names an account. (A session row's own
# `user`, read to find the caller's sessions, is the store's, not the request's.)
my @reads = $code =~ /(\$\w+\s*=\s*_json_body\(\)[^;]*;)/g;
ok( scalar @reads, 'Account.pm reads the request body' );
like( $_, qr/\A\$req\s*=\s*_json_body\(\)/, "the body is read into \$req: $_" ) for @reads;
unlike( $code, qr/_json_body\(\)\s*->/, 'and never dereferenced in place' );
unlike( $code,
    qr/\$req->\{\s*['"]?(?:user|username|account|login|name|actor|principal|owner)['"]?\s*\}/,
    'Account.pm reads no account-naming key from the request' );

done_testing;
