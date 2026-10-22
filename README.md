# Airbnb European Cities — Data Analytics

## Project Overview
An end-to-end data analytics project exploring Airbnb listings across 10 European cities: Amsterdam, Athens, Barcelona, Berlin, Budapest, Lisbon, London, Paris, Rome, and Vienna.

The project covers data collection, SQL-based data preparation, data warehousing, and interactive reporting in Power BI.

## Project Workflow
1. **Web Scraping:** Collected listing information, including listing names, prices, nights, ratings, reviews, Superhost status, Guest Favorite status, and listing URLs.
2. **SQL Server:** Prepared and organized the collected data for analysis.
3. **Data Warehouse:** Designed a dimensional model using `fact_listing`, `dim_listing`, and `dim_city`.
4. **Power BI:** Built an interactive dashboard with two report pages.

## Dashboard Pages

### 1. City Overview
- Total listings
- Median nightly price
- Superhost percentage
- Guest Favorite percentage
- Nightly price comparison across cities

### 2. Price vs Rating
- Nightly price distribution
- Average rating by city for listings with at least five reviews
- Top 10 listings by review count
- Median reviews by city
- City filter for interactive exploration

## Tools & Technologies
Python, Selenium, Jupyter Notebook, SQL Server, Data Warehousing, Power BI, DAX.

## Important Notes
The dataset represents the listings collected from the search results returned for the selected cities and search conditions. It is not a random or representative sample of all Airbnb listings. Prices and listing details may change over time.

## Repository Structure
- `scraping/` — data collection notebook
- `sql/` — SQL scripts for data preparation and warehouse operations
- `data/` — shareable dataset, if permitted
- `powerbi/` — Power BI report and dashboard screenshots

## Disclaimer
This is an independent portfolio project for educational and analytical purposes. It is not affiliated with or endorsed by Airbnb.
