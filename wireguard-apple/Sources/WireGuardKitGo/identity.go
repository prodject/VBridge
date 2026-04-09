package main

import (
    "fmt"
    mathrand "math/rand"
)

type Profile struct {
    UserAgent       string
    SecChUa         string
    SecChUaMobile   string
    SecChUaPlatform string
}


var firstNames = []string{
    "Александр", "Дмитрий", "Максим", "Сергей", "Андрей", "Алексей", "Артём", "Илья",
    "Кирилл", "Михаил", "Никита", "Матвей", "Роман", "Егор", "Арсений", "Иван",
    "Денис", "Даниил", "Тимофей", "Владислав", "Игорь", "Павел", "Руслан", "Марк",
    "Анна", "Мария", "Елена", "Дарья", "Анастасия", "Екатерина", "Виктория", "Ольга",
    "Наталья", "Юлия", "Татьяна", "Светлана", "Ирина", "Ксения", "Алина", "Елизавета",
}

var lastNames = []string{
    "Иванов", "Смирнов", "Кузнецов", "Попов", "Васильев", "Петров", "Соколов", "Михайлов",
    "Новиков", "Федоров", "Морозов", "Волков", "Алексеев", "Лебедев", "Семенов", "Егоров",
    "Павлов", "Козлов", "Степанов", "Николаев", "Орлов", "Андреев", "Макаров", "Никитин",
    "Захаров", "Зайцев", "Соловьев", "Борисов", "Яковлев", "Григорьев", "Романов", "Воробьев",
}

var profiles = []Profile{
    // Windows Chrome
    {
        UserAgent:       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
        SecChUa:         `"Chromium";v="146", "Not-A.Brand";v="24", "Google Chrome";v="146"`,
        SecChUaMobile:   "?0",
        SecChUaPlatform: `"Windows"`,
    },
    {
        UserAgent:       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
        SecChUa:         `"Chromium";v="145", "Not-A.Brand";v="99", "Google Chrome";v="145"`,
        SecChUaMobile:   "?0",
        SecChUaPlatform: `"Windows"`,
    },
    {
        UserAgent:       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36",
        SecChUa:         `"Chromium";v="144", "Not-A.Brand";v="8", "Google Chrome";v="144"`,
        SecChUaMobile:   "?0",
        SecChUaPlatform: `"Windows"`,
    },

    // Windows Edge
    {
        UserAgent:       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 Edg/146.0.0.0",
        SecChUa:         `"Chromium";v="146", "Not-A.Brand";v="24", "Microsoft Edge";v="146"`,
        SecChUaMobile:   "?0",
        SecChUaPlatform: `"Windows"`,
    },
    {
        UserAgent:       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0",
        SecChUa:         `"Chromium";v="145", "Not-A.Brand";v="99", "Microsoft Edge";v="145"`,
        SecChUaMobile:   "?0",
        SecChUaPlatform: `"Windows"`,
    },

    // macOS Chrome
    {
        UserAgent:       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
        SecChUa:         `"Chromium";v="146", "Not-A.Brand";v="24", "Google Chrome";v="146"`,
        SecChUaMobile:   "?0",
        SecChUaPlatform: `"macOS"`,
    },
    {
        UserAgent:       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
        SecChUa:         `"Chromium";v="145", "Not-A.Brand";v="99", "Google Chrome";v="145"`,
        SecChUaMobile:   "?0",
        SecChUaPlatform: `"macOS"`,
    },

    // Linux Chrome
    {
        UserAgent:       "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
        SecChUa:         `"Chromium";v="146", "Not-A.Brand";v="24", "Google Chrome";v="146"`,
        SecChUaMobile:   "?0",
        SecChUaPlatform: `"Linux"`,
    },
    {
        UserAgent:       "Mozilla/5.0 (X11; Ubuntu; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36",
        SecChUa:         `"Chromium";v="144", "Not-A.Brand";v="8", "Google Chrome";v="144"`,
        SecChUaMobile:   "?0",
        SecChUaPlatform: `"Linux"`,
    },
}

func getRandomProfile() Profile {
    return profiles[mathrand.Intn(len(profiles))]
}

func generateName() string {
    if mathrand.Float32() < 0.3 {
        return firstNames[mathrand.Intn(len(firstNames))]
    }
    fn := firstNames[mathrand.Intn(len(firstNames))]
    ln := lastNames[mathrand.Intn(len(lastNames))]
    lastChar := fn[len(fn)-2:]
    if lastChar == "а" || lastChar == "я" {
        return fmt.Sprintf("%s %sа", fn, ln)
    }
    return fmt.Sprintf("%s %s", fn, ln)
}
