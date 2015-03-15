# LoLfever - random meta ftw
# Copyright (C) 2013, 2015  Florian Hassanen
# 
# This file is part of LoLfever.
#
# LoLfever is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package LolFever;

use Modern::Perl '2015';

use Mojolicious::Lite;
use Method::Signatures::Simple;

use Mojo::Path;

use Digest;

no warnings 'experimental::smartmatch';

my $config = plugin 'Config';
my $base = $config->{'base'} // '';

app->secrets(['HaShien233zyyY?']); 
my $salt = 'asdfp421c4 1r_';
app->defaults( layout => 'layout' );
app->ua->max_redirects(10);

my @base_path = @{ Mojo::Path->new($base)->leading_slash(0) };
app->hook(before_dispatch => sub {
  my $c = shift;
  
  my @base = splice @{ $c->req->url->path->leading_slash(0) }, 0, scalar @base_path;

  $c->rendered(404) unless @base ~~ @base_path;

  push @{ $c->req->url->base->path->trailing_slash(1) }, @base;
});

my %PARSE = ( mid => 'mid', 
              top => 'top',
              support => 'sup',
              adcarry => 'ad|bot',
              jungle => 'jun', );

my @ROLES = keys %PARSE;

func parse_role( $role_string ) {
    for my $role (@ROLES) {
        return $role if $role_string =~ /$PARSE{$role}/xmsi;
    }
    return;
}

func write_db( $file, $data ) {
    open(my $f, '>', $file);

    for my $key ( sort keys %$data ) {
        for my $value ( sort keys %{ $data->{$key} } ) {
            say {$f} "$key:$value" if $data->{$key}->{$value};
        }
    }

    close $f;
}

func read_db( $file ) {
    open(my $f, '<', $file);

    my %data;

    while(my $l = <$f>) {
        chomp $l;

        my ($key,$val) = split /:/xms, $l, 2;

        $data{$key} = {} unless defined $data{$key};

        $data{$key}->{$val} = 1;
    }

    close $f;

    return \%data;
}

post("/championdb" => method {
    $self->render_later;
    $self->delay(
        func ($d) {
            $self->ua->get('http://www.lolking.net/champions' => $d->begin);
            $self->ua->get('http://www.lolking.net/guides' => $d->begin);
            $self->ua->get('http://www.lolpro.com' => $d->begin);
        },
        func ($d, $champs, $guides, $frees) {
            my $db;
            my $free;
            my @errors;
            
            for my $c ( @{ $champs->res->dom->find('.champion-list tr') } ) {
                my $a = $c->at('.champion-list-icon > a');
                if( defined $a ) {
                    unless( $a->attr('href') =~ / ( [^\/]*? ) \z/xms ) {
                        push @errors, 'Could not parse champion name from: '.($a->attr('href'));
                    } else {
                        my $name = $1;
                        $name = 'wukong' if $name eq 'monkeyking';

                        my $role = $c->at('td:nth-last-of-type(2)');
                        unless( defined $role && defined $role->attr('data-sortval') ) {
                            push @errors, "No role found for champion $name";
                        } else {
                            my $r = parse_role($role->attr('data-sortval'));
                            
                            unless( defined $r ) {
                                push @errors, "Do not know what role this is: '".($role->attr('data-sortval'))."' (champion is '$name')";
                            } else {
                                $db->{$name}->{$r} = 1;
                            }
                        }
                    }
                }
            }

            for my $c ( @{ $guides->res->dom->find('#guides-champion-list > .big-champion-icon') } ) {
                my $name = lc( $c->attr('data-name') =~ s/[^a-zA-Z]//xmsgr );
                my @roles = map { $c->attr("data-meta$_") } @{['', 1..5]};
         
                unless( exists $db->{$name} ) {
                    push @errors, "No such champion: $name/".($c->{'name'});
                } else {
                    for my $role (@roles) {
                        next unless defined $role;
                        next unless $role =~ /\w/xms;

                        my $r = parse_role($role);

                        unless( $r ) {
                            push @errors, "Do not know what role this is again: '$role' (champion is '$name')";
                        } else {
                            $db->{$name}->{$r} = 1;
                        }
                    }
                }
            }

            for my $c ( @{ $frees->res->dom->find('li.game-champion') } ) {
                my @classes = split /\s+/xms, $c->attr('class');

                my ($name_info) = grep { /\A game-champion-/xms && !/\A game-champion-tag-/xms } @classes;

                if( $name_info =~ /\A game-champion-(.*) \z/xms ) {
                    my $name = $1 =~ s/[^a-z]//xmsgr;

                    unless( exists $db->{$name} ) {
                        push @errors, "What is this for a champion: $name?";
                    } else {
                        $free->{$name}->{'free'}  = 1 if 'game-champion-tag-free'     ~~ @classes;
                        $db->{$name}->{'top'}     = 1 if 'game-champion-tag-top'      ~~ @classes;
                        $db->{$name}->{'mid'}     = 1 if 'game-champion-tag-mid'      ~~ @classes;
                        $db->{$name}->{'adcarry'} = 1 if 'game-champion-tag-duo'      ~~ @classes && !( 'game-champion-tag-support' ~~ @classes );
                        $db->{$name}->{'support'} = 1 if 'game-champion-tag-support'  ~~ @classes;
                        $db->{$name}->{'jungle'}  = 1 if 'game-champion-tag-jungler'  ~~ @classes;
                    }
                }
            }

            write_db('champions.db', $db);
            write_db('free.db', $free);

            $self->render( 'championdb', errors => ( @errors ? \@errors : undef ), db => $db, free => $free, blacklist => read_db('blacklist.db'), whitelist => read_db('whitelist.db'), updated => 1, roles => [ sort @ROLES ], mode => 'champions' );
        }
    );
})->name('championdb');

func manage_list( $file, $champion, $role, $listed ) {
    my $list = read_db( $file );

    $list->{ $champion }->{ $role } = $listed;

    write_db( $file, $list );
}

func manage_blacklist( $champion, $role, $listed ) {
    manage_list( 'blacklist.db', $champion, $role, $listed );
}

func manage_whitelist( $champion, $role, $listed ) {
    manage_list( 'whitelist.db', $champion, $role, $listed );
}

get( "/champion/:champion/:role/blacklist" => method {
    manage_blacklist( $self->param('champion'), $self->param('role'), 1 );
    
    $self->redirect_to('championdb');
})->name('blacklist');

get( "/champion/:champion/:role/no_blacklist" => method {
    manage_blacklist( $self->param('champion'), $self->param('role'), 0 );
    
    $self->redirect_to('championdb');
})->name('no_blacklist');

get( "/champion/:champion/:role/whitelist" => method {
    manage_whitelist( $self->param('champion'), $self->param('role'), 1 );
    
    $self->redirect_to('championdb');
})->name('whitelist');

get( "/champion/:champion/:role/no_whitelist" => method {
    manage_whitelist( $self->param('champion'), $self->param('role'), 0 );
    
    $self->redirect_to('championdb');
})->name('no_whitelist');

get "/championdb" => method {
    my $db = read_db('champions.db');
    my $free = read_db('free.db');

    $self->render( 'championdb', errors => undef, db => $db, free => $free, blacklist => read_db('blacklist.db'), whitelist => read_db('whitelist.db'), updated => 0, roles => [ sort @ROLES ], mode => 'champions' );
};

get("/user/:name" => method {
    my $name = $self->param('name');
    unless( defined $name && $name =~ /\w/xms && -f "$name.db" ) {
        return $self->render( text => "No such user: $name" );
    }

    my $data = read_db("$name.db");
    my $champions = read_db('champions.db');
    my @names = sort ( keys %$champions );

    $self->render($self->param('edit') ? 'user_edit' : 'user', user => $name, names => \@names, roles => [ sort @ROLES ], owns => $data->{'owns'}, can => $data->{'can'}, pw => !!$data->{'pwhash'}, mode => 'profile' );
})->name('user');

post "/user/:name" => method {
    my $name = $self->param('name');

    unless( defined $name && $name =~ /\w/xms && -f "$name.db" ) {
        return $self->render( text => "No such user: $name", user => $name, mode => 'profile' );
    }

    my $data = read_db("$name.db");
    
    unless( $data->{'pw'} || $data->{'pwhash'} ) {
        return $self->render( text => "User deactivated: $name", user => $name, mode => 'profile' );
    }

    my $champions = read_db('champions.db');
    my @names = sort ( keys %$champions );

    my $d = Digest->new('SHA-512')->add( $salt );
    
    my $auth;

    if( $data->{'pwhash'} ) {
        ($auth) = keys %{ $data->{'pwhash'} };
    } else {
        my ($plain) = keys %{ $data->{'pw'} };
        $auth = $d->clone->add( $plain )->b64digest;
    }

    my $given = $d->clone->add( $self->param('current_pw') )->b64digest;
  
    unless( $auth eq $given ) {
        return $self->render( text => "invalid pw", user => $name, mode => 'profile' );
    }

    if( $self->param('new_pw_1') ) {
        unless( $self->param('new_pw_1') eq $self->param('new_pw_2') ) {
            return $self->redner( text => "new pws did not match" );
        } else {
            $data->{'pwhash'} = {} unless defined $data->{'pwhash'};
            $data->{'pwhash'}->{ $d->clone->add( $self->param('new_pw_1') )->b64digest } = 1;
        }
    }

    $data->{'can'} = {} unless defined $data->{'can'};
    for my $role (@ROLES) {
        $data->{'can'}->{$role} = !!$self->param("can:$role");
    }

    $data->{'owns'} = {} unless defined $data->{'owns'};
    for my $champ (@names) {
        $data->{'owns'}->{$champ} = !! $self->param("owns:$champ");
    }

    write_db("$name.db", $data);

    return $self->redirect_to;
};

method roll_form {
    my @users = map { /(.*)\.db\z/xms; $1 } (grep { !/champions|roll|free|blacklist|whitelist/xms } (glob '*.db'));

    my $db = read_db('champions.db');

    my @champions = keys( %$db );

    return $self->render( 'roll', users => [ sort @users ], roles => [ sort @ROLES ], champions => [ sort @champions ], players => undef, woroles => undef, wochampions => undef, roll => undef, fails => undef, mode => 'roll' );
};

get "" => \&roll_form;
get "/troll" => \&roll_form;

func select_random(@values) {
    my $len = scalar  @values;
    my $ran = int(rand($len));

    my @other = grep { $_ != $ran } (0..$len-1);

    return @values[$ran, @other];
}

func all_options( $db, $user, $free, $tabu_roles, $tabu_champions ) {
    return map {
        my $champion = $_;
        if ( ( $user->{'owns'}->{$champion} || $champion ~~ @$free ) && !( $champion ~~ @$tabu_champions ) ) {
            map {
                my $role = $_;
                if ( $user->{'can'}->{$role} && !( $role ~~ @$tabu_roles ) ) {
                    { champion => $champion, role => $role };
                } else { (); }
            } keys %{ $db->{$champion} };
        } else { (); }
    } keys %$db;
}

func combine_blacklist_whitelist( $db, $blacklist, $whitelist ) {
    return { map { 
        my $champ = $_;
        ( $champ => { map {
            my $role = $_;
            if ( ( $db->{$champ}->{$role} || $whitelist->{$champ}->{$role} ) && !$blacklist->{$champ}->{$role} ) {
                ( $role => 1 );
            } else { (); } 
        } @ROLES } );
    } keys %$db };
}

func trollify( $db ) {
    my $troll_db;

    for my $champ ( keys %$db ) {
        my @roles = keys %{ $db->{$champ} };
        push @roles, 'adcarry', 'support' if 'adcarry' ~~ @roles || 'support' ~~ @roles; # combine bot lane :)

        for my $troll_role ( grep { !( $_ ~~ @roles ) } @ROLES ) {
            $troll_db->{$champ}->{$troll_role} = 1;
        }
    }

    return $troll_db;
}

method roll( $trolling ) {
    my @players = grep { $_ } @{ $self->every_param('players') };
    my @woroles = grep { $_ } @{ $self->every_param('woroles') };
    my @wochampions = grep { $_ } @{ $self->every_param('wochampions') };
    
    my %player_specs = map { ( $_ => read_db("$_.db") ) } @players;

    my $db = read_db('champions.db');
    my @free = keys %{ read_db('free.db') };

    $db = combine_blacklist_whitelist( $db, read_db('blacklist.db'), read_db('whitelist.db') );
    $db = trollify( $db ) if $trolling;
    
    my @fails;

    my $TRIES = 42;

    my %roll;
    for (1..$TRIES) {
        undef %roll;
        my @u = @players;

        while( scalar @u ) {
            (my $user, @u) = select_random(@u);

            my @options = all_options($db, $player_specs{$user}, \@free, [ @woroles, map { $_->{'role'} } values %roll ], [ @wochampions, map { $_->{'champion'} } values %roll ]);
            
            unless( scalar @options ) {
                push @fails, { $user => { %roll } };
                last;
            }

            $roll{$user} = $options[ int(rand(scalar @options)) ];
        }

        last if( ( scalar ( keys %roll ) ) == ( scalar @players ) );
    }

    my @users = map { /(.*)\.db\z/xms; $1 } (grep { !/champions|roll|free|blacklist|whitelist/xms } (glob '*.db'));

    my @champions = keys( %$db );

    return $self->render( 'roll', users => [ sort @users ], roles => [ sort @ROLES ], champions => [ sort @champions ], players => \@players, woroles => \@woroles, wochampions => \@wochampions, 
                           roll => (scalar keys %roll ? \%roll : undef), fails => (scalar @fails ? $self->dumper(\@fails) : undef), mode => 'roll' );
}

get "/roll" => method {
    return $self->redirect_to('home');
};

post("" => method {
    return roll($self); # you cannot call the method directly, use function notation instead
})->name('home');

post("/troll" => method {
    return roll($self, 'trolling');
})->name('trollroll');

app->start;

__DATA__

@@ layouts/layout.html.ep
<html>
<!--
  - LoLfever - random meta ftw
  - Copyright (C) 2013, 2015  Florian Hassanen
  - 
  - This file is part of LoLfever.
  -
  - LoLfever is free software: you can redistribute it and/or modify
  - it under the terms of the GNU Affero General Public License as
  - published by the Free Software Foundation, either version 3 of the
  - License, or (at your option) any later version.
  - 
  - This program is distributed in the hope that it will be useful,
  - but WITHOUT ANY WARRANTY; without even the implied warranty of
  - MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  - GNU Affero General Public License for more details.
  - 
  - You should have received a copy of the GNU Affero General Public License
  - along with this program.  If not, see <http://www.gnu.org/licenses/>.
  -->
<head>
<title>LoL Fever</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link href="<%= url_for '/css/bootstrap.min.css' %>" rel="stylesheet" media="screen">
<link href="<%= url_for '/css/lolfever.css' %>" rel="stylesheet" media="screen">
</head>
<body>
<div class="container">
<nav class="navbar navbar-default">
    <div class="container-fluid">
        <div class="navbar-header">
            <button type="button" class="navbar-toggle collapsed" data-toggle="collapse" data-target="#navbar">
                <span class="sr-only">Toggle navigation</span>
                <span class="icon-bar"></span>
                <span class="icon-bar"></span>
                <span class="icon-bar"></span>
            </button>
            %= link_to LoLfever => 'home', {}, class => 'navbar-brand'
        </div>
        <div class="collapse navbar-collapse" id="navbar">
            <ul class="nav navbar-nav">
                <li <% if( $mode eq 'roll'      ) { %> class="active" <% } %> >
                    %= link_to Roll => 'home'
                </li>
                <li <% if( $mode eq 'champions' ) { %> class="active" <% } %> >
                    %= link_to Champions => 'championdb'          
                </li>
                <% if( $mode eq 'profile' ) { %> 
                    <li class="active">
                        %= link_to ( (stash 'user') . "'" . ( (stash 'user') =~ /s \z/xms ? '' : 's') . ' profile')                
                    </li> 
                <% } %>
            </ul>
        </div>
    </div>
</nav>
<%= content %>
<div style="margin-top: 40px" class="text-center"><small>This is free software. Get the <a href="https://github.com/H4ssi/lolfever">source</a>!</small></div>
</div>
<script src="<%= url_for '/js/jquery.min.js' %>"></script>
<script src="<%= url_for '/js/bootstrap.min.js' %>"></script>
</body>
</html>

@@ roll.html.ep

% if( defined $roll ) {
    <dl class="well well-sm dl-horizontal">
    % for my $player ( sort keys %$roll ) {
        <dt><%= $player %></dt><dd><%= $roll->{$player}->{'champion'} %> (<%= $roll->{$player}->{'role'} %>)</dd>
    % }
    </dl>
% }

%= form_for url_for() => (method => 'POST') => begin

<div class="form-group">
    <label>Players</label>
    % for my $u (@$users) {
        <div class="checkbox">
            <label>
                %= input_tag "players", type => 'checkbox', value => $u, $u ~~ @$players ? ( checked => 'checked' ) : ()
                %= link_to $u => 'user' => { name => $u }
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Excluded roles</label>
    % for my $r (@$roles) {
        <div class="checkbox">
            <label>
                %= input_tag "woroles", type => 'checkbox', value => $r, $r ~~ @$woroles ? ( checked => 'checked' ) : ()
                %= $r
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Excluded champions</label>
    % for my $i (0..3) {
        <select name="wochampions" class="form-control">
            <option value=""></option>
            % for my $c (@$champions) {
                <option value="<%= $c %>"
                    % if( $c eq ($wochampions->[$i] // '') ) {
                        selected="selected"
                    % }
                ><%= $c %></option>
            % }
        </select>
    % }
</div>

<button type="submit" class="btn btn-default">Roll</button>

% end 
%# of form

% if( defined $fails ) {
    <pre><%= $fails %></pre>
% }


@@ user.html.ep

<h3>Possible roles</h3>
<ul class="list-inline">
% for my $c (@$roles) {
    % if( $can->{$c} ) {
        <li><%= $c %></li>
    % }
% }
</ul>

<h3>Owned champions</h3>
<ul class="list-inline">
% for my $n (@$names) {
    % if( $owns->{$n} ) {
        <li><%= $n %></li>
    % }
% }
</ul>

%= link_to Edit => url_for->query(edit => 1) => (class => 'btn btn-default')


@@ user_edit.html.ep

%= form_for url_for() => (method => 'POST') => begin

<div class="form-group">
    <label>Possible roles</label>

    % for my $c (@$roles) {
        <div class="checkbox">    
            <label>
                %= input_tag "can:$c", type => 'checkbox', value => 1, $can->{$c} ? ( checked => 'checked' ) : ()
                <%= $c %>
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Owned champions</label>

    % for my $n (@$names) {
        <div class="checkbox">    
            <label>
                %= input_tag "owns:$n", type => 'checkbox', value => 1, $owns->{$n} ? ( checked => 'checked' ) : ()
                <%= $n %>
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Authentication</label>

    <div class="form-group">
        <label for="current_pw">
            Current password <strong>(required)</strong>
        </label>
        %= input_tag 'current_pw' => ( type => 'password', placeholder => 'Password', id => 'current_pw', class => 'form-control' )
    </div>

    <div class="form-group">
        <label for="new_pw_1">
            New password 
            % if( !$pw ) {
                <strong>(Password change required!)</strong>
            % } else {
                (Leave empty if you do not want to change your password)
            % }
        </label>
        %= input_tag 'new_pw_1' => ( type => 'password', placeholder => 'Password', id => 'new_pw_1', class => 'form-control' )
    </div>

    <div class="form-group">
        <label for="new_pw_2">
            Retype new password
        </label>
        %= input_tag 'new_pw_2' => ( type => 'password', placeholder => 'Password', id => 'new_pw_2', class => 'form-control' )
    </div>
</div>

<button type="submit" class="btn">Save</button>

% end
%# of form


@@ championdb.html.ep

%= form_for url_for() => (method => 'POST') => begin
    <button type="submit" class="btn">Update DB from the Interwebs</button>
    (You need to do this once per free champion rotation)
% end


% if( $updated ) {
    % if( defined $errors ) {
        <div class="alert alert-danger" role="alert">
            % for my $e (@$errors) {
                <p><%= $e %></p>
            % }
        </div>
    % } else {
        <div class="alert alert-success" role="alert">
            Champion DB was updated without errors!
        </div>
    % }
% }

<table class="table table-hover table-condensed champion-table"><tbody>
    % for my $c (sort keys %$db) {
        <tr>
            <th> 
                <%= $c %>
                % if( $free->{$c} ) {
                    <span class="label label-info">free</span>
                % }
            </th>
            % for my $r ( @$roles ) {
                <td>
                    % if( $db->{$c}->{$r} ) {
                        %= link_to $blacklist->{$c}->{$r} ? 'no_blacklist' : 'blacklist' => { champion => $c, role => $r } => begin
                            % if( $blacklist->{$c}->{$r} ) {
                                <s><%= $r %></s>
                            % } else {
                                <%= $r %>
                            % }
                        % end
                    % } else {
                        %= link_to $whitelist->{$c}->{$r} ? 'no_whitelist' : 'whitelist' => { champion => $c, role => $r } => begin
                            % if( $whitelist->{$c}->{$r} ) {
                                <u><%= $r %></u>
                            % } else {
                                <span class="non-role"><%= $r %></span>
                            % }
                        % end
                    % }
                </td>
            % }
        </tr>
    % }
</tbody></table>
