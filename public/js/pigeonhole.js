$(function(){
    $("#reload").click(function() {
        start_date = $('#start_date')[0].value;
        end_date   = $('#end_date')[0].value;
        search     = $('#search')[0].value;
        window.location.href = '../' + start_date + '/' + end_date + "?search=" + search;
    });

    $("#incidents-table").tablesorter({
        textExtraction: {
            4 : function(node, table, cellIndex) {
                return $(node).find('option:selected').text()
            }
        }
    });

    $( "#start_date" ).datepicker({
      dateFormat: "yy-mm-dd",
      maxDate: "-0",
      onClose: function( selectedDate ) {
        $( "#end_date" ).datepicker( "option", "minDate", selectedDate );
      }
    });

    $( "#end_date" ).datepicker({
      dateFormat: "yy-mm-dd",
      maxDate: "-0",
      onClose: function( selectedDate ) {
        $( "#start_date" ).datepicker( "option", "maxDate", selectedDate );
      }
    });
});
