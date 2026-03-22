(function($) {

function login_request() {
  var user = $('#login_form #login_user').val();
  var pass = $('#login_form #login_pass').val();
  var hash;

  var params = Ophal.getURLParams();
  var query_string = params.redirect ? 'redirect=' + encodeURIComponent(params.redirect) : '';

  /* Authenticate */
  $.ajax({
    type: 'POST',
    url: '/user/auth' + (query_string ? '?' + query_string : ''),
    contentType: 'application/json; charset=utf-8',
    data: JSON.stringify({user: user, pass: pass}),
    dataType: 'json',
    processData: false,
    success: function(data) {
      if (data.authenticated) {
	if (data.redirect) {
	  window.location = data.redirect;
	}
	else {
	  window.location = '/';
	}
      }
      else {
        alert('Login error! Please check your credentials.');
      }
    },
    error: function() {
      alert('Authentication error. Please try again later.');
    }
  });
}

$(document).ready(function() {
  $('#login_form #login_submit').click(function() {
    try {
      login_request();
    } finally {
      /* Prevent browser to send POST request, since we already did it */
       return false;
    }
  });
});

})(jQuery);
