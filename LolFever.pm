# LoLfever - random meta ftw
# Copyright (C) 2013  Florian Hassanen
# 
# This program is free software: you can redistribute it and/or modify
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

use Modern::Perl;

use threads;

use Mojolicious::Lite;
use Method::Signatures::Simple;

use URI;
use Web::Scraper;
use Data::Dumper;

use Digest;

my $config = plugin 'Config';
my $base = $config->{'base'} // '';

app->secret('asdfp421c4 1r_');
app->defaults( layout => 'layout' );

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

post("$base/championdb" => method {
    my $champion_list_thread = threads->create( sub {
        my $champion_list_scraper = scraper {
            process '.champion-list tr', 'champions[]' => scraper {
                # this custom process is used to prevent auto cast to URI
                # since this cannot be shared accross threads, its easier
                # to just take a string of the @href attribute
                process '.champion-list-icon > a', href => sub { return shift->attr('href'); };
                process '//td[last()-1]', role => '@data-sortval';
            };
        };
        return $champion_list_scraper->scrape( URI->new('http://www.lolking.net/champions') ); 
    });

    my $champion_guide_thread = threads->create( sub {
        my $champion_guide_scraper = scraper {
            process "#guides-champion-list > .big-champion-icon", 'champions[]' => { name => '@data-name', meta0 => '@data-meta', map { ( "meta$_" => "\@data-meta$_" ) } (1..5) };
        };
        return $champion_guide_scraper->scrape( URI->new('http://www.lolking.net/guides') );
    });

    my $free_rotation_thread = threads->create( sub {
        my $free_rotation_scraper = scraper {
            process 'li.game-champion', 'champions[]' => { class => '@class' };
        };
        return $free_rotation_scraper->scrape( URI->new('http://www.lolpro.com') );
    });

    my $db;
    my $free;
    my @errors;
    
    my $champions = $champion_list_thread->join();

    for my $c ( @{ $champions->{'champions'} } ) {
        if( defined $c->{'href'} ) {
            unless( $c->{'href'} =~ / ( [^\/]*? ) \z/xms ) {
                push @errors, 'Could not parse champion name from: '.($c->{'href'});
            } else {
                my $name = $1;
                $name = 'wukong' if $name eq 'monkeyking';

                unless( $c->{'role'} ) {
                    push @errors, "No role found for champion $name";
                } else {
                    my $r = parse_role($c->{'role'});
                    
                    unless( defined $r ) {
                        push @errors, "Do not know what role this is: '".($c->{'role'})."' (champion is '$name')";
                    } else {
                        $db->{$name}->{$r} = 1;
                    }
                }
            }
        }
        
    }

    my $champion_guides = $champion_guide_thread->join();

    for my $c ( @{ $champion_guides->{'champions'} } ) {
        my @roles = grep { defined && /\w/xms } @$c{ grep { / \A meta/xms } keys %$c };
        (my $name = $c->{'name'}) =~ s/[^a-zA-Z]//xmsg;
 
        unless( exists $db->{$name} ) {
            push @errors, "No such champion: $name/".($c->{'name'});
        } else {
            for my $role (@roles) {
                my $r = parse_role($role);

                unless( $r ) {
                    push @errors, "Do not know what role this is again: '$role' (champion is '$name')";
                } else {
                    $db->{$name}->{$r} = 1;
                }
            }
        }
    }

    my $free_rotation = $free_rotation_thread->join();

    for my $c ( @{ $free_rotation->{'champions'} } ) {
        my @classes = split /\s+/xms, $c->{'class'};

        my ($name_info) = grep { /\A game-champion-/xms && !/\A game-champion-tag-/xms } @classes;

        if( $name_info =~ /\A game-champion-(.*) \z/xms ) {
            (my $name = $1) =~ s/[^a-z]//xmsg;

            unless( exists $db->{$name} ) {
                push @errors, "What is this for a champion: $name?";
            } else {
                $free->{$name}->{'free'}  = 1 if 'game-champion-tag-free'     ~~ @classes;
                $db->{$name}->{'top'}     = 1 if 'game-champion-tag-top-lane' ~~ @classes;
                $db->{$name}->{'mid'}     = 1 if 'game-champion-tag-mid-lane' ~~ @classes;
                $db->{$name}->{'adcarry'} = 1 if 'game-champion-tag-bot-lane' ~~ @classes && !( 'game-champion-tag-support' ~~ @classes );
                $db->{$name}->{'support'} = 1 if 'game-champion-tag-support'  ~~ @classes;
                $db->{$name}->{'jungle'}  = 1 if 'game-champion-tag-jungler'  ~~ @classes;
            }
        }
    }

    write_db('champions.db', $db);
    write_db('free.db', $free);

    my $blacklist = read_db('blacklist.db');
    
    $self->render( 'championdb', errors => ( @errors ? \@errors : undef ), db => $db, free => $free, blacklist => $blacklist, updated => 1, mode => 'champions' );
})->name('championdb');

func manage_blacklist( $champion, $role, $listed ) {
    my $blacklist = read_db('blacklist.db');

    $blacklist->{ $champion }->{ $role } = $listed;

    write_db('blacklist.db', $blacklist);
}

get( "$base/champion/:champion/:role/troll" => method {
    manage_blacklist( $self->param('champion'), $self->param('role'), 1 );
    
    $self->redirect_to('championdb');
})->name('troll');

get( "$base/champion/:champion/:role/legit" => method {
    manage_blacklist( $self->param('champion'), $self->param('role'), 0 );
    
    $self->redirect_to('championdb');
})->name('legit');

get "$base/championdb" => method {
    my $db = read_db('champions.db');
    my $free = read_db('free.db');
    my $blacklist = read_db('blacklist.db');

    $self->render( 'championdb', errors => undef, db => $db, free => $free, blacklist => $blacklist, updated => 0, mode => 'champions' );
};

get("$base/user/:name" => method {
    my $name = $self->param('name');
    unless( defined $name && $name =~ /\w/xms && -f "$name.db" ) {
        return $self->render( text => "No such user: $name" );
    }

    my $data = read_db("$name.db");
    my $champions = read_db('champions.db');
    my @names = sort ( keys %$champions );

    $self->render($self->param('edit') ? 'user_edit' : 'user', user => $name, names => \@names, roles => [ sort @ROLES ], owns => $data->{'owns'}, can => $data->{'can'}, pw => !!$data->{'pwhash'}, mode => 'profile' );
})->name('user');

post "$base/user/:name" => method {
    my $name = $self->param('name');

    unless( defined $name && $name =~ /\w/xms && -f "$name.db" ) {
        return $self->render( text => "No such user: $name" );
    }

    my $data = read_db("$name.db");
    
    unless( $data->{'pw'} || $data->{'pwhash'} ) {
        return $self->render( text => "User deactivated: $name" );
    }

    my $champions = read_db('champions.db');
    my @names = sort ( keys %$champions );

    my $d = Digest->new('SHA-512')->add( app->secret );
    
    my $auth;

    if( $data->{'pwhash'} ) {
        ($auth) = keys %{ $data->{'pwhash'} };
    } else {
        my ($plain) = keys %{ $data->{'pw'} };
        $auth = $d->clone->add( $plain )->b64digest;
    }

    my $given = $d->clone->add( $self->param('current_pw') )->b64digest;
  
    unless( $auth eq $given ) {
        return $self->render( text => "invalid pw" );
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
    my @users = map { /(.*)\.db\z/xms; $1 } (grep { !/champions|roll|free|blacklist/xms } (glob '*.db'));

    my $db = read_db('champions.db');

    my @champions = keys( %$db );

    return $self->render( 'roll', users => [ sort @users ], roles => [ sort @ROLES ], champions => [ sort @champions ], players => undef, woroles => undef, wochampions => undef, roll => undef, fails => undef, mode => 'roll' );
};

get "$base" => \&roll_form;
get "$base/troll" => \&roll_form;

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

func combine_blacklist( $db, $blacklist ) {
    return { map { 
        my $champ = $_;
        ( $champ => { map {
            my $role = $_;
            if ( $db->{$champ}->{$role} && !$blacklist->{$champ}->{$role} ) {
                ( $role => 1 );
            } else { (); } 
        } keys %{ $db->{$champ} } } );
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
    my @players = grep { $_ } $self->param('players');
    my @woroles = grep { $_ } $self->param('woroles');
    my @wochampions = grep { $_ } $self->param('wochampions');
    
    my %player_specs = map { ( $_ => read_db("$_.db") ) } @players;

    my $db = read_db('champions.db');
    my @free = keys %{ read_db('free.db') };
    my $blacklist = read_db('blacklist.db');

    $db = combine_blacklist( $db, $blacklist );
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

    my @users = map { /(.*)\.db\z/xms; $1 } (grep { !/champions|roll|free|blacklist/xms } (glob '*.db'));

    my @champions = keys( %$db );

    return $self->render( 'roll', users => [ sort @users ], roles => [ sort @ROLES ], champions => [ sort @champions ], players => \@players, woroles => \@woroles, wochampions => \@wochampions, 
                           roll => (scalar keys %roll ? \%roll : undef), fails => (scalar @fails ? Dumper(\@fails) : undef), mode => 'roll' );
}

get "$base/roll" => method {
    return $self->redirect_to('base');
};

post("$base" => method {
    return roll($self); # you cannot call the method directly, use function notation instead
})->name('base');

post("$base/troll" => method {
    return roll($self, 'trolling');
})->name('trollroll');

app->start;

__DATA__

@@ layouts/layout.html.ep
<html>
<!--
  - LoLfever - random meta ftw
  - Copyright (C) 2013  Florian Hassanen
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
<link href="<%= $config->{'base'} %>/css/bootstrap.min.css" rel="stylesheet" media="screen">
</head>
<body>
<div class="container">
<div class="navbar">
    <div class="navbar-inner">
%=      link_to LoLfever => 'base', {}, class => 'brand'
        <ul class="nav">
            <li <% if( $mode eq 'roll'      ) { %> class="active" <% } %> >
%=              link_to Roll => 'base'
            </li>
            <li <% if( $mode eq 'champions' ) { %> class="active" <% } %> >
%=              link_to Champions => 'championdb'          
            </li>
            <% if( $mode eq 'profile' ) { %> 
                <li class="active">
%=                  link_to ( (stash 'user') . "'" . ( (stash 'user') =~ /s \z/xms ? '' : 's') . ' Profile')                
                </li> 
            <% } %>
        </ul>
    </div>
</div>
<%= content %>
<div style="margin-top: 40px" class="text-center"><small>This is free software. Get the <a href="https://github.com/H4ssi/lolfever">source</a>!</small></div>
</div>
<script src="<%= $config->{'base'} %>/js/bootstrap.min.js"></script>
</body>
</html>

@@ roll.html.ep

% if( defined $roll ) {
    <dl class="well dl-horizontal">
%   for my $player ( sort keys %$roll ) {
    <dt><%= $player %></dt><dd><%= $roll->{$player}->{'champion'} %> (<%= $roll->{$player}->{'role'} %>)</dd>
%   }
    </dl>
% }

%= form_for url_for() => (method => 'POST', class => 'form-horizontal') => begin

<div class="control-group">
    <label class="control-label">
    Players
    </label>
    <div class="controls">
%   for my $u (@$users) {
        <label class="checkbox">
%=      input_tag "players", type => 'checkbox', value => $u, $u ~~ @$players ? ( checked => 'checked' ) : ()
%=      link_to $u => 'user' => { name => $u }
        </label>
%   }
    </div>
</div>

<div class="control-group">
    <label class="control-label">
    Excluded roles
    </label>
    <div class="controls">
%   for my $r (@$roles) {
        <label class="checkbox">
%=      input_tag "woroles", type => 'checkbox', value => $r, $r ~~ @$woroles ? ( checked => 'checked' ) : ()
%=      $r
        </label>
%   }
    </div>
</div>

<div class="control-group">
    <label class="control-label">
    Excluded champions
    </label>
    <div class="controls">
%   for my $i (0..3) {
        <select name="wochampions">
            <option value=""></option>
%       for my $c (@$champions) {
            <option value="<%= $c %>"
%           if( $c eq ($wochampions->[$i] // '') ) {
                selected="selected"
%           }
            ><%= $c %></option>
%       }
        </select><br/>
%   }
    </div>
</div>

<div class="control-group">
    <div class="controls">
    <button type="submit" class="btn">Roll</button>
    </div>
</div>
% end

% if( defined $fails ) {
<pre>
%= $fails
</pre>
% }


@@ user.html.ep
<h2>Possible roles</h2>
<ul class="inline">
% for my $c (@$roles) {
%   if( $can->{$c} ) {
        <li><%= $c %></li>
%   }
% }
</ul>
<h2>Owned champions</h2>
<ul class="inline">
% for my $n (@$names) {
%   if( $owns->{$n} ) {
        <li><%= $n %></li>
%   }
% }
</ul>
%= link_to Edit => url_for->query(edit => 1)

@@ user_edit.html.ep
%= form_for url_for() => (method => 'POST') => begin
<fieldset>
<legend>
Possible roles
</legend>
% for my $c (@$roles) {
    <label class="checkbox">
%= input_tag "can:$c", type => 'checkbox', value => 1, $can->{$c} ? ( checked => 'checked' ) : ()
    <%= $c %>
    </label>
% }
<br/>
<legend>
Owned champions
</legend>
% for my $n (@$names) {
    <label class="checkbox">
%= input_tag "owns:$n", type => 'checkbox', value => 1, $owns->{$n} ? ( checked => 'checked' ) : ()
    <%= $n %>
    </label>
% }
<br/>
<legend>
Authentication
</legend>
<label for="current_pw">
Current password <strong>(required)</strong>
</label>
%= input_tag 'current_pw' => ( type => 'password', id => 'current_pw' )
<label for="new_pw_1">
New password 
% if( !$pw ) {
    <strong>(Password change required!)</strong>
% } else {
    (Leave empty if you do not want to change your password)
% }
</label>
%= input_tag 'new_pw_1' => ( type => 'password', id => 'new_pw_1' )
<label for="new_pw_2">
Retype new password
</label>
%= input_tag 'new_pw_2' => ( type => 'password', id => 'new_pw_2' )
<br>
<button type="submit" class="btn">Save</button>
</fieldset>
% end

@@ championdb.html.ep
%= form_for url_for() => (method => 'POST') => begin
<button type="submit" class="btn">Update DB from the Interwebs</button>
(You need to do this once per free champion rotation)
% end
% if( $updated ) {
%   if( defined $errors ) {
        <div class="alert alert-error">
%       for my $e (@$errors ) {
            <p><%= $e %></p>
%       }
        </div>
%   } else {
    <div class="alert alert-success">
        Champion DB was updated without errors!
    </div>
%   }
% }
<dl class="dl-horizontal">
% for my $c (sort keys %$db) {
    <dt><%= $c %></dt>
    <dd><!--
%   if( $free->{$c} ) {
        --><span class="label label-important">free</span> <!--
%   }
%   my $count = 0;
%   for my $r ( sort keys %{ $db->{$c} } ) {
%       if( $count++ != 0 ) { 
            --> <!--
%       }
--><%=  link_to $blacklist->{$c}->{$r} ? 'legit' : 'troll' => { champion => $c, role => $r } => begin %><!--
%           if( $blacklist->{$c}->{$r} ) {
                --><s><%= $r %></s><!--
%           } else {
                --><%= $r %><!--
%           }
--><%=  end %><!--
%   }
    --></dd>
% }
</dl>
