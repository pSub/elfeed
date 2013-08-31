var INITIAL_QUERY = '@2days';

function favicon(url) {
    return URI(url).path('favicon.ico').search('')
        .toString().replace(/\?$/, '');
}

function entryFill(entry) {
    entry.favicon = favicon(entry.link);
    var date = new Date(entry.date);
    entry.dateString = [
        1900 + date.getYear(),
        1 + date.getMonth(),
        date.getDate()
    ].join('-');
    entry.classes = entry.tags.map(function(tag) {
        return 'tag-' + tag;
    }).join(' ');
}

function SearchCtrl($scope, $http) {
    $scope.query = INITIAL_QUERY;
    $scope.busy = false;
    $scope.dirty = true;

    $scope.update = function(blur) {
        if (!$scope.busy) {
            $scope.busy = true;
            $scope.dirty = false;
            $http.get(URI('/elfeed/search').search({
                q: $scope.query
            }).toString()).success(function(data) {
                data.forEach(entryFill);
                $scope.entries = data;
                $scope.busy = false;
                if ($scope.dirty) $scope.update();
            });
        } else {
            $scope.dirty = true;
        }

        if (blur) {
            // Is there a "right" way to do this? I don't think there is.
            document.getElementById('query').blur();
        }
    };

    $scope.time = 0;
    function poll() {
        $http.get(URI('/elfeed/update').search({
            time: $scope.time
        }).toString()).success(function(data) {
            $scope.time = data;
            $scope.update();
            poll();
        });
    }

    poll();
}

function ViewCtrl($scope) {
    $scope.ref = null;
    //$scope.ref = "77a01f799ef6ac4a1aa4bfc218050a95eeb0875a";
}
