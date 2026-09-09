0..11|%{"On the $("First Second Third Fourth Fifth Sixth Seventh Eighth Ninth Tenth Eleventh Twelfth".Split()[$_]) day of Christmas
My true love sent to me
$('A Partridge in a Pear Tree.;Two Turtle Doves, and;Three French Hens,;Four Calling Birds,;Five Gold Rings,;Six Geese-a-Laying,;Seven Swans-a-Swimming,;Eight Maids-a-Milking,;Nine Ladies Dancing,;Ten Lords-a-Leaping,;Eleven Pipers Piping,;Twelve Drummers Drumming,'.Split(';')[$_..0]-join"
")
"}

# Adds one char trying to eliminate $()
0..11|%{"On the "+"First Second Third Fourth Fifth Sixth Seventh Eighth Ninth Tenth Eleventh Twelfth".Split()[$_]+" day of Christmas
My true love sent to me
$('A Partridge in a Pear Tree.;Two Turtle Doves, and;Three French Hens,;Four Calling Birds,;Five Gold Rings,;Six Geese-a-Laying,;Seven Swans-a-Swimming,;Eight Maids-a-Milking,;Nine Ladies Dancing,;Ten Lords-a-Leaping,;Eleven Pipers Piping,;Twelve Drummers Drumming,'.Split(';')[$_..0]-join"
")
"}