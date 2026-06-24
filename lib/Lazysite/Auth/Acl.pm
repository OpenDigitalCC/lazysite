package Lazysite::Auth::Acl;

# SM074 per-file ACL store (lazysite/auth/acls.json) and the ownership/allow
# checks, shared (SM079). Context is $DOCROOT, set by the script. The
# operator-bypass decision (_is_operator) is request-context-bound and stays in
# the manager, which combines it with _acl_allows here.

use strict;
use warnings;
use JSON::PP ();
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Exporter 'import';

our @EXPORT_OK = qw(load_acls save_acls _acl_norm _to_list _acl_allows _acls_path
    _is_operator _acl_denied);

our $DOCROOT;    # set by the script

# Manager auth-state, set per request by the dispatcher (the operator-bypass
# decision). A token client is never an operator; otherwise the manager group
# membership decides.
our $auth_user           = '';
our $token_auth          = 0;
our $manager_groups_conf = '';

sub _acls_path { "$DOCROOT/lazysite/auth/acls.json" }

sub load_acls {
    my $path = _acls_path();
    return {} unless -f $path;
    open my $fh, '<', $path or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $m = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return ref $m eq 'HASH' ? $m : {};
}

sub save_acls {
    my ($map) = @_;
    my $path = _acls_path();
    my $dir  = dirname($path);
    make_path($dir) unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->pretty->encode($map);
    close $fh;
    chmod 0640, $tmp;
    return rename $tmp, $path;
}

# Strip leading slashes so an ACL key matches the manager's relative paths.
sub _acl_norm { my $r = shift; $r =~ s{^/+}{} if defined $r; return $r }

# Normalise a list value (arrayref or comma/space string) to an arrayref,
# or undef if not provided.
sub _to_list {
    my ($v) = @_;
    return undef unless defined $v;
    return [ grep { length } @$v ] if ref $v eq 'ARRAY';
    return [ grep { length } split /[,\s]+/, $v ];
}

# Does the ACL for $rel allow $user $mode access? No entry = allowed (the
# account's scope governs); owner always allowed; else membership of the
# mode's allow-list.
sub _acl_allows {
    my ( $rel, $mode, $user ) = @_;
    my $a = load_acls()->{ _acl_norm($rel) };
    return 1 unless $a;
    return 1 if defined $a->{owner} && defined $user && $a->{owner} eq $user;
    my $list = $a->{$mode};
    return 1 unless ref $list eq 'ARRAY' && @$list;
    for my $u (@$list) { return 1 if defined $u && defined $user && $u eq $user }
    return 0;
}

# Operator bypass (manager-only). A token (control-API) client is NEVER an
# operator - per-file ACL ownership applies to it like any WebDAV partner. An
# unsecured site (no manager_groups) treats cookie clients as operators; the
# 'local' user is always operator; else manager-group membership decides. The
# token path never consults the client-influenceable X-Remote-Groups.
sub _is_operator {
    return 0 if $token_auth;
    return 1 unless length $manager_groups_conf;       # unsecured / dev
    return 1 if ( $auth_user // '' ) eq 'local';
    my %mg = map { $_ => 1 } grep { length } split /[,\s]+/, $manager_groups_conf;
    for my $g ( grep { length } split /[,\s]+/, ( $ENV{HTTP_X_REMOTE_GROUPS} // '' ) ) {
        return 1 if $mg{$g};
    }
    return 0;
}

# Combine operator bypass + the per-file allow check; returns a refusal hashref
# or undef if access is allowed.
sub _acl_denied {
    my ( $rel, $mode, $user ) = @_;
    return undef if _is_operator();
    return undef if _acl_allows( $rel, $mode, $user );
    return { ok => 0, error => "You do not have $mode access to this file" };
}

1;
