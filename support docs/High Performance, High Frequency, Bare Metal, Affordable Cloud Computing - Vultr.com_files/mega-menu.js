window.onload = () => {
	// body group search
	$('.mm-header-input').keyup((e) => {
		let searchTerm = $(e.target).val().toLowerCase().replaceAll(" ", "");
		bodyFilterOptions($(e.target).parent().siblings(".mm__body-groups"), searchTerm);
		solutionFilterOptions($(e.target).parent().siblings(".mm__solutions"), searchTerm);
	})

	// filter and hide children first, then full group if no matching children in group
	function bodyFilterOptions(searchGroup, searchTerm) {
		$(searchGroup).find($('.mm__body-group')).each((i, element) => {
			if (!$(element).find('.mm__body-group-sub-link a').text().toLowerCase().replaceAll(" ", "").includes(searchTerm) &&
				!$(element).find('.mm__primary-link-text').text().toLowerCase().replaceAll(" ", "").includes(searchTerm))
			{
				$(element).fadeOut('fast');
			}
			else
			{
				$(element).find('.mm__body-group-sub-link').each((i, subElement) => {
					if (!$(subElement).text().toLowerCase().replaceAll(" ", "").includes(searchTerm))
					{
						$(subElement).fadeOut('fast');
					}
					else
					{
						$(subElement).fadeIn('fast');
					}
				});
				$(element).fadeIn('fast');
			}
		});
	}

	// filter and hide children first, then full group if no matching children in group
	function solutionFilterOptions(searchGroup, searchTerm) {
		$(searchGroup).find('.mm__solution-group').each((i, element) => {
			if (!$(element).find('.mm__solution-item a').text().toLowerCase().replaceAll(" ", "").includes(searchTerm))
			{
				$(element).fadeOut('fast');
			}
			else
			{
				$(element).find('.mm__solution-item a').each((i, subElement) => {
					if (!$(subElement).text().toLowerCase().replaceAll(" ", "").includes(searchTerm))
					{
						$(subElement).fadeOut('fast');
					}
					else
					{
						$(subElement).fadeIn('fast');
					}
				});
				$(element).fadeIn('fast');
			}
		});
	}
}