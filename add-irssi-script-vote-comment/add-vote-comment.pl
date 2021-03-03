#! perl
use strict;
use warnings;
use utf8;

my $MAX_COMMENTS = 35;
#my $MAX_COMMENTS = 8;
my $MAX_AT_ONCE = 10 * 2 + 6;

BEGIN {
    require Net::GitHub::V3::Query;
    no warnings 'redefine';
    my $_orig_make_request = \&Net::GitHub::V3::Query::_make_request;
    *Net::GitHub::V3::Query::_make_request = sub {
	my ($self, @args) = @_;
	my $res = $_orig_make_request->($self, @args);
	$res->header('Status', $res->code);
	$res
    };
}

use Hash::Util qw(lock_keys lock_ref_keys lock_ref_keys_plus);
use Net::GitHub::V3;
use CPAN::Meta::YAML 'LoadFile';
use JSON::PP;

Net::GitHub::V3::Query::__build_methods(
    'Net::GitHub::V3::Issues',
    lock_issue => { url => "/repos/%s/%s/issues/%s/lock", method => 'PUT', check_status => 204,
		},
    unlock_issue => { url => "/repos/%s/%s/issues/%s/lock", method => 'DELETE', check_status => 204,
		  },
   );

$| = 1;
sub output (@) {
    print @_;
}

sub ng {
    my ($user_proj) = @_;

    my $gh = Net::GitHub::V3->new(
	($ENV{GITHUB_TOKEN} ? (access_token => $ENV{GITHUB_TOKEN}) : ())
       );
    my $proj = $user_proj;
    my ($user, $project) = split '/', $proj, 2;
    return unless $user && $project;
    $gh->set_default_user_repo($user, $project);
    $gh
}

sub get_issues {
    my ($ng, $start) = @_;

    # my $ua = $ng->ua;
    # $ua->default_header(Accept => 'application/vnd.github.squirrel-girl-preview');

    my %r;

    my $iss = $ng->issue;

    my %res;

    my $in = $start + 0;
 RST: while (1) {
	output "C($in";
	local $@;
	my @comm = eval { $iss->comments($in) };
	my $err = $@;
	output ")";
	if ($err) {
	    $err =~ s/ at .*//s;
	    output "E($err)\n";
	    last;
	}

	$r{$in} = +{};
	$r{$in}{issue} = $iss->issue($in);
	$r{$in}{comments} = [@comm];
	$r{$in}{comment_count} = scalar @comm;
	lock_ref_keys_plus($r{$in}, qw(next_issue_ref_comment next_issue_num));

	for my $c (@comm) {
	    $c->{issue_num} = $in;
	    $c->{issue_ref} = $r{$in}{issue};
	    lock_ref_keys($c);
	    $c->{body} =~ s/\r\n/\n/g;
	    if ($c->{body} =~ /\A## (.*?[._].*?)$/m || $c->{body} =~ /\A(.*?[._].*?)\n---\n/m) {
		my $script = $1;
		$res{$script} = $c;
	    } elsif ($c->{body} =~ /\A#(\d+)\Z/) {
		my $next_in = $1 + 0;
		$r{$in}{next_issue_ref_comment} = $c;
		$r{$in}{next_issue_num} = $next_in;
		$in = $next_in;
		next RST;
	    }
	}
	output "\n";
	last;
    }
    my %rr = (issue_map => \%r, script_map => \%res);
    return lock_keys(%rr)
}

sub create_new_votes_issue {
    my ($ng, $res) = @_;
    my $iss = $ng->issue;

    my $isu = $iss->create_issue( {
        title => 'votes',
    } );

    my ($last_num) = sort { $b <=> $a } keys %{$res->{issue_map}};

    # FAKE ISU
    # my $isu = +{ number => ($last_num||0)+1 }; 

    $res->{issue_map}{$isu->{number}}{issue} = $isu;
    $res->{issue_map}{$isu->{number}}{comments} = [];
    $res->{issue_map}{$isu->{number}}{comment_count} = 0;
    lock_ref_keys_plus($res->{issue_map}{$isu->{number}}, qw(next_issue_ref_comment next_issue_num));

    $iss->update_issue( $isu->{number}, {
        state => 'closed'
    } );

    $isu->{number}
}

sub find_last_issue {
    my ($res) = @_;
    my ($last_issue) = grep { !$res->{issue_map}{$_}{next_issue_num} } sort keys %{$res->{issue_map}};
    return $last_issue
}

sub main {
    my ($script_file, $start, $user_proj) = @_;

    die "Error: Must specify script_file\n" unless $script_file;

    if ($start && $start !~ /^\d+$/) {
	($user_proj, $start) = ($start, $user_proj);
    }

    $start ||= 1;

    $user_proj //= $ENV{GITHUB_REPOSITORY};
    die "Error: Must specify user/project\n" unless $user_proj;

    output "SF(";
    my $x = LoadFile($script_file);
    output scalar @$x, ")\n";

    my $ng = ng($user_proj);
    my $iss = $ng->issue;
    my $res;
    use Storable qw(retrieve nstore);
    my $cache = 'get_issue_results.sto';
    my $cache_c = {};
    if (-e $cache) {
	output "L.";
	$cache_c = retrieve($cache);
	output "..";
    }
    if ($cache_c && $cache_c->{$user_proj}) {
	output "(c!)\n";
	$res = $cache_c->{$user_proj};
    } else {
	$res = get_issues($ng, $start);
	$cache_c->{$user_proj} = $res;
	nstore $cache_c, $cache;
    }

    # Dump($res);
    my $done = 0;
    my $checked = 0;
    my $todo = 0;
    my %move_next_issue_comment;
    for my $sc (sort { $a->{modified} cmp $b->{modified} } @$x) {
	output ".$sc->{filename}";
	if ($done + scalar keys %move_next_issue_comment >= $MAX_AT_ONCE) {
	    output "?\n";
	    $todo++;
	} else {
	    my $c;
	    my $found_issue;
	    $sc->{description} //= '';
	    if (exists $res->{script_map}{$sc->{filename}}) {
		output "..I($res->{script_map}{$sc->{filename}}{issue_num})C($res->{script_map}{$sc->{filename}}{id})";
		$c = $res->{script_map}{$sc->{filename}};
	    } else {
		for my $issue_num (sort { $a <=> $b } keys %{$res->{issue_map}}) {
		    my $off = $res->{issue_map}{$issue_num}{next_issue_ref_comment} ? 0 : 1;
		    if ($res->{issue_map}{$issue_num}{comment_count} + $off < $MAX_COMMENTS) {
			output "..I($issue_num)";
			if ($res->{issue_map}{$issue_num}{issue}{locked}) {
			    output "oLo";
			    $iss->unlock_issue($issue_num);
			    $done++;
			    $res->{issue_map}{$issue_num}{issue}{locked} = JSON::PP::false;
			}
			output "P";
			$found_issue = $issue_num;
			last;
		    }
		}
		unless ($found_issue) {
		    my ($last_issue) = find_last_issue($res);
		    output "..N(";
		    my $new_issue = create_new_votes_issue($ng, $res);
		    $done++;
		    output "$new_issue";
		    sleep 5;
		    output ")";
		    if ($last_issue) {
			my $lr = $res->{issue_map}{$last_issue};
			$lr->{next_issue_num} = $new_issue;
			$move_next_issue_comment{$last_issue}++;
		    }
		    $found_issue = $new_issue;
		}
		$move_next_issue_comment{$found_issue}++;
		# my $c = [" -- comment object for $sc->{filename} --"];
		output "~(";
		$c = $iss->create_comment($found_issue, {
		    body => "$sc->{filename}\n---\n$sc->{description}\n\nClick on +😃︎ :+1: :-1: to add your votes . ❲ Github login required .. ❳ "
		});
		output "$c->{id})";
		$done++;
		$c->{issue_num} = $found_issue;
		$c->{issue_ref} = $res->{issue_map}{$found_issue}{issue};
		lock_ref_keys($c);
		$c->{body} =~ s/\r\n/\n/g;
		push @{$res->{issue_map}{$found_issue}{comments}}, $c;
		$res->{issue_map}{$found_issue}{comment_count}++;
		$res->{script_map}{$sc->{filename}} = $c;
		sleep 5;
	    }
	    # $c->{body} =~ s{❲ Github login required .. ❳ \Z}{❲ Github [login](https://github.com/login?return_to=/$user_proj/issues/$c->{issue_num}%23issuecomment-$c->{id}) required .. ❳ }m;
	    my $body = "$sc->{filename}\n---\n$sc->{description}\n\nClick on +😃︎ :+1: :-1: to add your votes . ❲ Github [login](https://github.com/login?return_to=/$user_proj/issues/$c->{issue_num}%23issuecomment-$c->{id}) required .. ❳ ";
	    if ($body ne $c->{body}) {
		output "U";
		$iss->update_comment($c->{id}, { body => $body });
		$done++;
		$c->{body} = $body;
		sleep 5;
	    }
	    output "\n";
	    $checked++;
	}
    }
    output "\@($done)";
    output ".($checked)??($todo)/(";
    output scalar @$x;
    output ")\n";

    my ($last_issue) = find_last_issue($res);
    if ($last_issue && $res->{issue_map}{$last_issue}{comment_count}) {
	output "L(";
	my $new_issue = create_new_votes_issue($ng, $res);
	my $lr = $res->{issue_map}{$last_issue};
	$lr->{next_issue_num} = $new_issue;
	$move_next_issue_comment{$last_issue}++;
	output "$new_issue";
	$iss->lock_issue($new_issue);
	$res->{issue_map}{$new_issue}{issue}{locked} = JSON::PP::true;
	output ")\n";
    }
    for my $issue_num (sort { $a <=> $b } keys %move_next_issue_comment) {
	output "M($issue_num->$res->{issue_map}{$issue_num}{next_issue_num})+$move_next_issue_comment{$issue_num}";
	# my $c = [ " -- redirect comment: $issue_num --> $res->{issue_map}{$issue_num}{next_issue_num} -- "];
	# post new comment
	my $c = $iss->create_comment($issue_num, {
	    body => "#$res->{issue_map}{$issue_num}{next_issue_num}"
	});
	output ".";
	push @{$res->{issue_map}{$issue_num}{comments}}, $c;
	$res->{issue_map}{$issue_num}{comment_count}++;
	if ($res->{issue_map}{$issue_num}{next_issue_ref_comment}) {
	    # delete old comment
	    output "X($res->{issue_map}{$issue_num}{next_issue_ref_comment}{id}";
	    $iss->delete_comment($res->{issue_map}{$issue_num}{next_issue_ref_comment}{id});
	    $res->{issue_map}{$issue_num}{comment_count}--;
	    output ")\n";
	} else {
	    output "\n";
	}
	$res->{issue_map}{$issue_num}{next_issue_ref_comment} = $c;
    }
    output "s(";
    nstore $cache_c, $cache;
    output ")\n";
    #Dump($cache_c);
}

local *_ = \@ARGV;
&main;
