require 'crawler_rocks'
require 'pry'
require 'json'
require 'iconv'

require 'thread'
require 'thwait'

class HochiBookCrawler
  include CrawlerRocks::DSL

  def initialize
    @base_url = "http://hochitw.com"
    @index_url = "http://hochitw.com/index_down.php"
  end

  def books
    @books = []
    @detail_links = []
    @threads = []

    # SECTION 1:
    #   we need to collect all book links in each category
    #   expand sidebar categories and try each
    visit @index_url

    @categories =
      Hash[
        @doc.css('[id*=SubMenu] a')
          .map{|a| [a.text, URI.join(@index_url, a["href"]).to_s] }
          .select{|arr| arr[0].match(/.+\((\d+)\)/)}
      ]

    # @categories.keys[1..4].each do |key|
    @categories.keys.each do |key|
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 10)
      )
      category = @categories[key]
      book_count = 1
      key.match(/.+\((?<b_c>\d+)\)/) { |m| book_count = m[:b_c].to_i }
      page_counts = book_count / 14 + 1
      @threads << Thread.new do
        print "\n#{key}:"
        (1..page_counts).each do |page_count|
          print "#{page_count}, "
          r = RestClient.get "#{category}&Page=#{page_count}"
          page = Nokogiri::HTML(r.to_s)

          _links = page.css('#product:nth-of-type(1) a').select {|a| a["href"].include?("openCatID")}
          @detail_links.concat( _links.map {|l| URI.join(@index_url, l["href"]).to_s } )
        end # end each page
      end # end Thread new do
    end
    ThreadsWait.all_waits(*@threads)
    @detail_links.uniq!

    puts "\n#####################\n"

    # SECTION 2:
    #   crawl each page and parse book info
    @threads = []
    @detail_links.each_with_index do |url, i|
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 20)
      )
      @threads << Thread.new do
        r = RestClient.get url
        doc = Nokogiri::HTML(r.to_s.encode("UTF-8", invalid: :replace, undef: :replace))

        table_selector = '//table[@cellpadding="1"][@cellspacing="0"][@width="100%"][@border="0"][@bgcolor="#DFEFFF"][@bordercolor="#ffffff"]'
        name = doc.xpath(table_selector + '/tr[1]').text

        internal_code = nil; price = nil; isbn = nil; barcode = nil;
        author = nil; publisher = nil;
        doc.xpath(table_selector + '/td').each do |td|
          datas = td.css('td')

          internal_code ||= datas[1].text if datas[0].text == '編號'
          price ||= datas[1].text.gsub(/[^\d]/, '').to_i if datas[0].text == '定價'

          if datas[0].text == 'ISBN/條碼'
            _split = find_split(datas[1].text)
            isbn ||= datas[1].text.split(_split)[0] && datas[1].text.split(_split)[0].strip
            barcode ||= datas[1].text.split(_split)[1] && datas[1].text.split(_split)[1].strip
          end

          if datas[0].text == '作(譯)者/出版商'
            _split = find_split(datas[1].text)
            author ||= datas[1].text.split(_split)[0] && datas[1].text.split(_split)[0].strip
            publisher ||= datas[1].text.split(_split)[1] && datas[1].text.split(_split)[1].strip
          end

          if datas[0].text == '年代/版次'
            # year ||= datas[1].text.split('/')[0] && datas[1].text.split('/')[0].strip
            edition ||= datas[1].text.split('/')[1] && datas[1].text.split('/')[1].strip
          end
        end # end each td (actually row)

        external_image_url = URI.join(@index_url, doc.css('#p1p img')[0]["src"] ).to_s unless doc.css('#p1p img').empty?

        @books << {
          name: name,
          isbn: isbn,
          barcode: barcode,
          author: author,
          publisher: publisher,
          price: price,
          internal_code: internal_code,
          external_image_url: external_image_url,
          url: url
        }

        print "#{i+1} / #{@detail_links.count}\n"
      end # Thread new do
    end # end each urls

    ThreadsWait.all_waits(*@threads)
    @books
  end

  def find_split str
      ['/', '／', '／'].each { |sp| return sp if str.include?(sp) }
      return nil
  end

end

cc = HochiBookCrawler.new
File.write('hochi_books.json', JSON.pretty_generate(cc.books))
