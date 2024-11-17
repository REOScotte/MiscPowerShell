$pairs = @()
(1..10) | % {
    $first = $_
    (1..10) | % {
        $second = $_
        $pairs += [PSCustomObject]@{
            First  = $first
            Second = $second
            Sum    = $first + $second
        }
    }
}

$order = $pairs | Sort-Object { Get-Random }

$html = @'
<html><body>
<style type="text/css">
    body{background-color: gray;}
    num-zero  { color:red        ;}
    num-one   { color:blue       ;}
    num-two   { color:yellow     ;}
    num-three { color:lightgreen ;}
    num-four  { color:orange     ;}
    num-five  { color:purple     ;}
    num-six   { color:pink       ;}
    num-seven { color:darkred    ;}
    num-eight { color:darkblue   ;}
    num-nine  { color:darkgreen  ;}
    num-plus  { color:black      ;}
    num-equals{ color:black      ;}
    table, th, td {
      font-family:     Arial Black;
      font-size:       21px;
      border:          1px solid black;
      border-collapse: collapse;
      padding:         7px;
      text-align:      center
    }
</style>
<table>
'@

$table = @'
<table>
'@

$perRow = 5
$i = 0
(0..99) | % {
    $equation = $order[$_]
    $first = $equation.First
    $second = $equation.Second
    $sum = $equation.Sum
    $text = "  <td>$first + $second _ $sum</td>`n"

    if ($i -eq 0) {
        $table += "<tr>`n"
    }

    $table += $text
    $i++

    if ($i -eq $perRow) {
        $table += "</tr>`n"
        $i = 0
    }
}

$table = $table -replace '0', '<num-zero>0</num-zero>'
$table = $table -replace '1', '<num-one>1</num-one>'
$table = $table -replace '2', '<num-two>2</num-two>'
$table = $table -replace '3', '<num-three>3</num-three>'
$table = $table -replace '4', '<num-four>4</num-four>'
$table = $table -replace '5', '<num-five>5</num-five>'
$table = $table -replace '6', '<num-six>6</num-six>'
$table = $table -replace '7', '<num-seven>7</num-seven>'
$table = $table -replace '8', '<num-eight>8</num-eight>'
$table = $table -replace '9', '<num-nine>9</num-nine>'
$table = $table -replace '\+', '<num-plus>+</num-plus>'
$table = $table -replace '_', '<num-equals>=</num-equals>'

$html += $table
$html += '</table></body></html>'

$html | Out-File AdditionTable.htm -Encoding ascii
.\AdditionTable.htm
Start-Sleep -Seconds 2
del .\AdditionTable.htm