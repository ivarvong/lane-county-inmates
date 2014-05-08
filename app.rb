require 'sinatra'
require 'httparty'
require 'json'
require 'redis'
require 'celluloid/autostart'
require 'dotenv'
Dotenv.load unless ENV['RACK_ENV'] == 'production'

ENV['WORKER_KEY'] ||= 'test'
puts "WORKER_KEY is #{ENV['WORKER_KEY']}"

$redis = Redis.new

class UOFindPeople
	def search(search_name)
		# for a search name string, return an **array** of matching names from UO Find People
		# cache searches in redis
		hash_key = "uo_student_cache_v1"
		if $redis.hexists(hash_key, search_name)
			result = JSON.parse $redis.get(hash_key, search_name)
		else
			result = JSON.parse( 
				HTTParty.get("http://uoregon.edu/findpeople/autocomplete/person/#{search_name.gsub(' ', '%20')}") 
			).map{|k, v| k }
			$redis.hset(hash_key, search_name, JSON.generate(result))
		end
		result 
	end
end

class JailViewer

	include Celluloid
	
	def inmate_request_xml(date_string)
		%Q{<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><SearchBooking xmlns="http://tempuri.org/"><pLastName></pLastName><pFirstName></pFirstName><pBookingFromDate>#{date_string}T00:00:00</pBookingFromDate><pBookingFromto>#{date_string}T00:00:00</pBookingFromto><pReleasedFromDate>0001-01-01T00:00:00</pReleasedFromDate><pReleasedFromTo>0001-01-01T00:00:00</pReleasedFromTo><pCustody>ALL</pCustody><pIncludeDOB>false</pIncludeDOB></SearchBooking></s:Body></s:Envelope>}
	end
	
	def get_inmates(date_string)
		inmates = HTTParty.post(
			'http://inmateinformation.lanecounty.org/PublicJailViewerServer.svc',
			body: inmate_request_xml(date_string),
			headers: {
				"Content-Type" => "text/xml; charset=utf-8",
				"SOAPAction"   => "http://tempuri.org/IPublicJailViewerServer/SearchBooking"
			}
		).to_h["Envelope"]["Body"]["SearchBookingResponse"]["SearchBookingResult"]["clsBooking"]
		$redis.set('latest_inmate_data', JSON.generate({time: Time.now.utc.to_i, data: inmates}))
		inmates
	end

	def update
		date_strings = ((Date.today-2)..(Date.today+1)).map{|d| d.strftime }

		date_strings.each do |date_string|
			get_inmates(date_string).each do |inmate|	
				name = "#{inmate['FirstName']} #{inmate['LastName']}"
				puts name
				results = UOFindPeople.search(name)
				puts results.count
				puts results
				puts " " 
			end
		end
	end

end

get "/_/:#{ENV['WORKER_KEY']}" do
	JailViewer.new.async.update()
end

get '/latest.json' do
	content_type 'application/json'
	$redis.get('latest_inmate_data')
end

get '/' do
	puts request.host_with_port
	erb :index
end

