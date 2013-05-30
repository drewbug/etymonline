require 'rubygems'
require 'neography'
require 'sinatra/base'
require 'uri'
require 'open-uri'
require 'net/http'
require 'json'
require 'cgi'
require 'nokogiri'
require 'set'

class Neovigator < Sinatra::Application
  set :haml, :format => :html5 
  set :app_file, __FILE__

  configure do
    @@updating = false
  end

  configure :test do
    require 'net-http-spy'
    Net::HTTP.http_logger_options = {:verbose => true} 
  end

  configure :production do
    require 'newrelic_rpm'
  end

  helpers do
    def link_to(url, text=url, opts={})
      attributes = ""
      opts.each { |key,value| attributes << key.to_s << "=\"" << value << "\" "}
      "<a href=\"#{url}\" #{attributes}>#{text}</a>"
    end

    def neo
      @neo = Neography::Rest.new(ENV['NEO4J_URL'] || "http://localhost:7474")
    end
  end

  def neighbours
    {"order"         => "depth first",
     "uniqueness"    => "none",
     "return filter" => {"language" => "builtin", "name" => "all_but_start_node"},
     "depth"         => 1}
  end

  def node_id(node)
    case node
      when Hash
        node["self"].split('/').last
      when String
        node.split('/').last
      else
        node
    end
  end

  def get_properties(node)
    properties = "<ul>"
    node["data"].each_pair do |key, value|
        properties << "<li><b>#{key}:</b> #{value}</li>"
      end
    properties + "</ul>"
  end

  get '/resources/show' do
    content_type :json

    node = neo.get_node(params[:id]) 
    if node
    connections = neo.traverse(node, "fullpath", neighbours)
    incoming = Hash.new{|h, k| h[k] = []}
    outgoing = Hash.new{|h, k| h[k] = []}
    nodes = Hash.new
    attributes = Array.new

    connections.each do |c|
       c["nodes"].each do |n|
         nodes[n["self"]] = n["data"]
       end
       rel = c["relationships"][0]

       if rel["end"] == node["self"]
         incoming["Incoming"] << {:values => nodes[rel["start"]].merge({:id => node_id(rel["start"]) }) }
       else
         outgoing["Outgoing"] << {:values => nodes[rel["end"]].merge({:id => node_id(rel["end"]) }) }
       end
    end

    incoming.merge(outgoing).each_pair do |key, value|
      attributes << {:id => key.split(':').last, :name => key, :values => value.collect{|v| v[:values]} }
    end

    attributes = [{"name" => "No Relationships","name" => "No Relationships","values" => [{"id" => "#{params[:id]}","name" => "No Relationships "}]}] if attributes.empty?
    @node = {:details_html => "<h2>Neo ID: #{node_id(node)}</h2>\n<p class='summary'>\n#{get_properties(node)}</p>\n",
             :data => {:attributes => attributes, 
                       :name => node["data"]["name"],
                       :id => node_id(node)}
              }
    @node.to_json
    
    else
      nil.to_json
    end
  end

  get '/' do
    puts @neoid = params["neoid"]
    haml :index
  end
  
  get '/term/:term' do
    neoid = node_id(neo.get_node_index('terms', 'term', params["term"]).first)
    redirect "/?neoid=#{neoid}"
  end

  get '/admin' do
    redirect "/admin/"
  end

  get '/admin/' do
    node_count = neo.execute_query("START n=node(*) RETURN count(n)")['data'][0][0]
    erb :admin, :locals => {:node_count => node_count, :updating => @@updating}
  end

  post '/admin/update' do
    unless @@updating
      Thread.new do
        @@updating = {status: 'building terms list', terms: Set.new}
        neo.create_node_index("terms")
        ('a'..'z').each do |letter|
          @@updating[:last_letter] = letter
          pages = [0]
          Nokogiri::HTML(open("http://www.etymonline.com/index.php?l=#{letter}")).css('a').each do |link|
            match = link["href"].match(/index.php\?l=#{letter}&p=(\d+)/)
            result = match.captures.first if match
            pages << result.to_i unless result.nil?
          end
          (0..pages.uniq.last).each do |page|
            @@updating[:last_page] = [page+1, pages.uniq.last+1]
            Nokogiri::HTML(open("http://www.etymonline.com/index.php?l=#{letter}&p=#{page}")).css('a').each do |link|
              match = link["href"].match(/index.php\?term=([^ &]+)&/)
              result = CGI.unescape(match.captures.first) if match
              @@updating[:terms] << result unless result.nil?
            end
          end
        end
        @@updating[:status] = 'populating database'
        @@updating[:terms].each do |term|
          @@updating[:last_term] = term
          if neo.get_node_index('terms', 'term', term)
            node1 = neo.get_node_index('terms', 'term', term)
          else
            node1 = neo.create_node('name' => term)
            neo.add_node_to_index('terms', 'term', term, node1)
          end
          @@updating[:last_node] = node1
          
          Nokogiri::HTML(open("http://www.etymonline.com/index.php?term=#{CGI.escape(term)}")).css('a').each do |link|
            match = link["href"].match(/index.php\?term=([^ &]+)&/)
            result = CGI.unescape(match.captures.first) if match
            if result
              if neo.get_node_index('terms', 'term', result)
                node2 = neo.get_node_index('terms', 'term', result)
              else
                node2 = neo.create_node('name' => result)
                neo.add_node_to_index('terms', 'term', result, node2)
              end
              if ((term != result) and (node1 != node2))
                existing = neo.execute_query("START n1=node(#{node_id(node1.first)}), n2=node(#{node_id(node2.first)}) MATCH n1-[:links]->n2 RETURN count(*)")
                if (existing and (existing['data'][0][0] == 0))
                  neo.create_relationship("links", node1, node2)
                  @@updating[:last_relationship] = [term, result]
                end
              end
            end
          end
        end
        @@updating = false
      end
    end
    redirect back
  end

end
